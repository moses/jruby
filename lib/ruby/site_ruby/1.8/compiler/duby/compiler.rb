require 'compiler/builder'
require 'compiler/duby/typer'
require 'jruby'

module Compiler
  module PrimitiveRuby
    JObject = java.lang.Object.java_class
    JClass = java.lang.Class.java_class
    JString = java.lang.String.java_class
    Void = java.lang.Void::TYPE
    System = java.lang.System.java_class
    PrintStream = java.io.PrintStream.java_class
    JInteger = java.lang.Integer.java_class
    Jint = Java::int.java_class
    JavaClass = Java::JavaClass
    
    class CompileError < Exception
      def initialize(position, message)
        full_message = "Compile error at #{position.file}:#{position.start_line}: #{message}"
        super(full_message)
      end
    end
    
    # reload 
    module Java::OrgJrubyAst
      class Node
        def compile(builder)
          # default behavior is to raise, to expose missing nodes
          raise CompileError.new(position, "Unsupported syntax: #{self}")
        end
      end
  
      class ArgsNode
        def compile(builder)
          raise("PRuby only supports normal args") if opt_args || rest_arg != -1 || block_arg_node
          return unless args
          args.child_nodes.each do |arg|
            builder.local(arg.name)
          end
        end
      end
  
      class ArrayNode
        def compile(builder)
          # not implemented
          raise
        end
      end
      
      class ClassNode
        def compile(builder)
          cb = builder.public_class(cpath.name)
          body_node.compile(cb)
        end
      end
  
      class BlockNode
        def compile(builder)
          child_nodes.each do |node|
            builder.line node.position.start_line
            
            node.compile(builder)
          end
        end
      end
      
      class CallNode
        def compile(builder)
          receiver_type = receiver_node.type(builder)
          
          if receiver_type.primitive?
            # we're performing an operation against a primitive, map it accordingly
            compile_primitive(receiver_type, builder)
          else
            case name
            when "new"
              compile_new(receiver_type, builder)
            else
              compile_call(receiver_type, builder)
            end
          end
        end
        
        def compile_call(receiver_type, builder)
          receiver_node.compile(builder)

          # I removed this because inference is working...but will it be needed under some circumstances?
#          # inefficient to cast every time; better inference will help
#          builder.checkcast(receiver_type)

          compile_args(builder)

          if (receiver_type.interface?)
            builder.invokeinterface receiver_type, mapped_name(builder), signature(builder)
          else
            builder.invokevirtual receiver_type, mapped_name(builder), signature(builder)
          end
        end
        
        def compile_args(builder)
          args_list = args_node.child_nodes.to_a
          args_list.each_index do |idx|
            node = args_list[idx]
            node.compile(builder)
          end
        end
        
        def compile_primitive(type, builder)
          receiver_node.compile(builder)

          if !args_node || args_node.size != 1
            raise CompileError.new(position, "Primitive operations must have exactly one argument")
          end
          
          node = args_node.get(0)
          # TODO: check or cast types according to receiver's type
          node.compile(builder)

          case type
          when Jint
            case name
            when "+"
              builder.iadd
            when "-"
              builder.isub
            else
              raise CompileError.new(position, "Primitive int operation #{name} not supported")
            end
          else
            raise CompileError.new(position, "Primitive #{type} operations not supported")
          end
        end
        
        def compile_new(type, builder)
          builder.new type
          builder.dup
          
          compile_args(builder)
          
          builder.invokespecial type, mapped_name(builder), signature(builder)
        end
      end
  
      class Colon2Node
      end
      
      class ConstNode
      end
      
      class DefnNode
        def compile(builder)
          first_real_node = body_node
          first_real_node = body_node.child_nodes[0] if BlockNode === body_node
          while NewlineNode === first_real_node
            first_real_node = first_real_node.next_node
          end
          
          # determine signature from declaration line
          signature = first_real_node.signature(builder) if HashNode === first_real_node
          
          signature ||= [Void]
          
          builder.method2(mapped_name(builder), *signature) do |method|
            # Run through any type declarations first
            first_real_node.declare_types(method) if HashNode === first_real_node

            # declare args that may not have been declared already
            args_node.compile(method)
            
            body_node.compile(method)
            
            # Expectation is that last element leaves the right type on stack
            case signature[0]
            when Void
              method.returnvoid
            when Jint
              method.ireturn
            else
              method.areturn
            end
          end
        end
      end
      
      class DefsNode
        def compile(builder)
          first_real_node = body_node
          first_real_node = body_node.child_nodes[0] if BlockNode === body_node
          while NewlineNode === first_real_node
            first_real_node = first_real_node.next_node
          end
          
          # determine signature from declaration line
          signature = first_real_node.signature(builder) if HashNode === first_real_node
          
          signature ||= [Void]
          
          builder.static_method2(name, *signature) do |method|
            # Run through any type declarations first
            first_real_node.declare_types(method) if HashNode === first_real_node

            # declare args that may not have been declared already
            args_node.compile(method)
            
            body_node.compile(method)
            
            # Expectation is that last element leaves the right type on stack
            case signature[0]
            when Void
              method.returnvoid
            when Jint
              method.ireturn
            else
              method.areturn
            end
          end
        end
      end
  
      class FCallNode
        def compile(builder)
          case name
          when "puts"
            compile_puts(builder)
          when "import"
            compile_import(builder)
          else
            builder.aload 0
            arg_types = []
            args_node.child_nodes.each do |node|
              node.compile(builder)
              arg_types << node.type(builder)
            end
            
            builder.invokevirtual builder.this, name, builder.method_signature(name, arg_types)
          end
        end
        
        def compile_puts(builder)
          builder.getstatic System, "out", [PrintStream]

          arg_types = []
          args_node.child_nodes.each do |node|
            node.compile(builder)
            arg_types << node.type(builder)
          end

          builder.invokevirtual PrintStream, "println", special_signature(PrintStream, builder)
        end
        
        def compile_import(builder)
          args_node.child_nodes.each do |node|
            case node
            when StrNode
              builder.import(node.value)
            else
              raise CompilerError.new(position, "Imports only allow strings right now")
            end
          end
        end
      end
      
      class FixnumNode
        def compile(builder)
          builder.ldc_int(value)
        end
      end
      
      class HashNode
        def compile(builder)
          @declared ||= false
          unless @declared
            # TODO: compile
            super
          end
        end
      end
      
      class IfNode
        def compile(builder)
          f = builder.label
          done = builder.label
          condition = self.condition
          condition = condition.next_node while NewlineNode === condition
          
          case condition
          when CallNode
            case condition.receiver_node.type(builder)
            when Jint
              case condition.name
              when "<"
                args = condition.args_node
                raise CompileError.new(position, "int < must have exactly one argument") if !args || args.size != 1
                
                condition.receiver_node.compile(builder)
                args.get(0).compile(builder)
                
                # test >= for jump
                builder.if_icmpge(f)
                
                then_body.compile(builder)
                builder.goto(done)
                
                f.set!
                else_body.compile(builder)
                
                done.set!
              end
            else
              raise CompileError.new(position, "Conditionals on non-primitives not supported: #{condition.inspect}")
            end
          else
            raise CompileError.new(position, "Non-call conditionals not supported: #{condition.inspect}")
          end
        end
      end
      
      class InstVarNode
        def compile(builder)
          builder.getfield(mapped_name(builder))
        end
      end
      
      class InstAsgnNode
        def compile(builder)
          builder.field(mapped_name(builder), value_node.type(builder))
          value_node.compile(builder)
          builder.putfield(mapped_name(builder))
        end
      end
      
      class LocalAsgnNode
        def compile(builder)
          local_index = builder.local(name, value_node.type(builder))
          value_node.compile(builder)
          case type(builder)
          when Jint
            builder.istore(local_index)
          else
            builder.astore(local_index)
          end
        end
      end
      
      class LocalVarNode
        def compile(builder)
          local_index = builder.local(name)
          case type(builder)
          when Jint
            builder.iload(local_index)
          else
            builder.aload(local_index)
          end
        end
      end
      
      class ModuleNode
        def compile(builder)
          builder.package(cpath.name) {
            body_node.compile(builder)
          }
        end
      end
  
      class NewlineNode
        def compile(builder)
          builder.line position.start_line
          next_node.compile(builder)
        end
      end
      
      class ReturnNode
        def compile(builder)
          value_node.compile(builder)
          builder.areturn
        end
      end
  
      class RootNode
        def compile(builder)
          # builder is class builder
      
          if body_node
            body_node.compile(builder)
          end
        end
      end
      
      class SelfNode
        def compile(builder)
          builder.local("this")
        end
      end
  
      class StrNode
        def compile(builder)
          builder.ldc value
        end
      end
      
      class SymbolNode
      end
  
      class VCallNode
        def compile(builder)
          builder.aload 0

          builder.invokevirtual builder.this, name, builder.method_signature(name, [])
        end
      end
    end
  end
end

if $0 == __FILE__
  n = JRuby.parse(File.read(ARGV[0]), ARGV[0])
  compiler = Compiler::FileBuilder.new(ARGV[0])
  n.compile(compiler)
  
  compiler.generate
end