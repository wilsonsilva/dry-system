# frozen_string_literal: true

require "pathname"
require "dry/system/constants"
require_relative "constants"
require_relative "identifier"
require_relative "magic_comments_parser"

module Dry
  module System
    # A configured component directory within the container's root. Provides access to the
    # component directory's configuration, as well as methods for locating component files
    # within the directory
    #
    # @see Dry::System::Config::ComponentDir
    # @api private
    class ComponentDir
      # @!attribute [r] config
      #   @return [Dry::System::Config::ComponentDir] the component directory configuration
      #   @api private
      attr_reader :config

      # @!attribute [r] container
      #   @return [Dry::System::Container] the container managing the component directory
      #   @api private
      attr_reader :container

      # @api private
      def initialize(config:, container:)
        @config = config
        @container = container
      end

      # Returns a component for the given key if a matching source file is found within
      # the component dir
      #
      # This searches according to the component dir's configured namespaces, in order of
      # definition, with the first match returned as the component.
      #
      # @param key [String] the component's key
      # @return [Dry::System::Component, nil] the component, if found
      #
      # @api private
      def component_for_identifier(key)
        namespaces.each do |namespace|
          identifier = Identifier.new(key, separator: container.config.namespace_separator)

          next unless identifier.start_with?(namespace.key)

          if (file_path = find_component_file(identifier, namespace))
            return build_component(identifier, namespace, file_path)
          end
        end

        nil
      end

      def each_component
        return enum_for(:each_component) unless block_given?

        each_file do |file_path, namespace|
          yield component_for_path(file_path, namespace)
        end
      end

      private

      def namespaces
        config.namespaces.to_a.map { |namespace| normalize_namespace(namespace) }
      end

      # Returns an array of "normalized" namespaces, safe for loading components
      #
      # This works around the issue of a namespace being added for a nested path but
      # _without_ specifying a key namespace. In this case, the key namespace will defaut
      # to match the path, meaning it will contain path separators instead of the
      # container's configured `namespace_separator` (due to `Config::Namespaces` not
      # being able to know the configured `namespace_separator`), so we need to replace
      # the path separators with the proper `namespace_separator` here (where we _do_ know
      # what it is).
      def normalize_namespace(namespace)
        if namespace.path&.include?(PATH_SEPARATOR) && namespace.default_key?
          namespace = namespace.class.new(
            path: namespace.path,
            key: namespace.key.gsub(PATH_SEPARATOR, container.config.namespace_separator),
            const: namespace.const
          )
        end

        namespace
      end

      def each_file
        return enum_for(:each_file) unless block_given?

        raise ComponentDirNotFoundError, full_path unless Dir.exist?(full_path)

        namespaces.each do |namespace|
          files(namespace).each do |file|
            yield file, namespace
          end
        end
      end

      def files(namespace)
        if namespace.path?
          Dir[File.join(full_path, namespace.path, "**", RB_GLOB)].sort
        else
          non_root_paths = namespaces.to_a.reject(&:root?).map(&:path)

          Dir[File.join(full_path, "**", RB_GLOB)].reject { |file_path|
            Pathname(file_path).relative_path_from(full_path).to_s.start_with?(*non_root_paths)
          }.sort
        end
      end

      # Returns the full path of the component directory
      #
      # @return [Pathname]
      def full_path
        container.root.join(path)
      end

      # Returns a component for a full path to a Ruby source file within the component dir
      #
      # @param path [String] the full path to the file
      # @return [Dry::System::Component] the component
      def component_for_path(path, namespace)
        separator = container.config.namespace_separator

        key = Pathname(path).relative_path_from(full_path).to_s
          .sub(RB_EXT, EMPTY_STRING)
          .scan(WORD_REGEX)
          .join(separator)

        identifier = Identifier.new(key, separator: separator)
          .namespaced(
            from: namespace.path&.gsub(PATH_SEPARATOR, separator),
            to: namespace.key
          )

        build_component(identifier, namespace, path)
      end

      def find_component_file(identifier, namespace)
        # To properly find the file within a namespace with a key, we should strip the key
        # from beginning of our given identifier
        if namespace.key
          identifier = identifier.namespaced(from: namespace.key, to: nil)
        end

        file_name = "#{identifier.key_with_separator(PATH_SEPARATOR)}#{RB_EXT}"

        component_file =
          if namespace.path?
            full_path.join(namespace.path, file_name)
          else
            full_path.join(file_name)
          end

        component_file if component_file.exist?
      end

      def build_component(identifier, namespace, file_path)
        options = {
          inflector: container.config.inflector,
          **component_options,
          **MagicCommentsParser.(file_path)
        }

        Component.new(identifier, namespace: namespace, **options)
      end

      def component_options
        {
          auto_register: auto_register,
          loader: loader,
          memoize: memoize
        }
      end

      def method_missing(name, *args, &block)
        if config.respond_to?(name)
          config.public_send(name, *args, &block)
        else
          super
        end
      end

      def respond_to_missing?(name, include_all = false)
        config.respond_to?(name) || super
      end
    end
  end
end
