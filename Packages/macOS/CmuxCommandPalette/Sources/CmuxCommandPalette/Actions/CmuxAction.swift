import Foundation

/// A stable argument contract shared by every presentation of a cmux action.
public struct CmuxActionArgumentDefinition: Sendable, Equatable {
    /// One finite value offered by an interactive action adapter.
    public struct Choice: Sendable, Equatable, Identifiable {
        /// Stable value supplied to the action handler and automation callers.
        public let value: String
        /// Localized label shown by interactive adapters.
        public let title: String

        /// Uses the stable wire value as this choice's identity.
        public var id: String { value }

        /// Creates one finite action-argument choice.
        /// - Parameters:
        ///   - value: Stable value supplied to the action handler.
        ///   - title: Localized label shown to the user.
        public init(value: String, title: String) {
            self.value = value
            self.title = title
        }
    }

    /// The value representation accepted on the wire and in configuration.
    public enum ValueType: String, Sendable {
        case string
        case path
        case boolean
    }

    /// Stable argument name.
    public let name: String
    /// Localized argument label shown by interactive adapters.
    public let title: String
    /// Expected value representation.
    public let valueType: ValueType
    /// Whether automation callers must supply this argument.
    public let required: Bool
    /// Whether an explicitly supplied empty string is valid.
    public let allowsEmpty: Bool
    /// Finite accepted values, or an empty array when the value is free-form.
    public let choices: [Choice]

    /// Creates a static action argument contract.
    public init(
        name: String,
        title: String? = nil,
        valueType: ValueType = .string,
        required: Bool = true,
        allowsEmpty: Bool = false,
        choices: [Choice] = []
    ) {
        self.name = name
        self.title = title ?? name
        self.valueType = valueType
        self.required = required
        self.allowsEmpty = allowsEmpty
        self.choices = choices
    }
}

/// Identifies the adapter invoking an action.
public enum CmuxActionInvocationSource: Sendable, Equatable {
    /// The command palette may collect missing arguments interactively.
    case commandPalette
    /// A CLI or socket caller must supply required arguments directly.
    case automation
}

/// One invocation of a statically defined cmux action.
public struct CmuxActionInvocation: Sendable, Equatable {
    /// Adapter that initiated the invocation.
    public let source: CmuxActionInvocationSource
    /// Named argument values supplied by the adapter.
    public let arguments: [String: String]
    /// Caller working directory used to resolve relative `path` arguments.
    public let workingDirectory: String?

    /// Creates an action invocation.
    public init(
        source: CmuxActionInvocationSource,
        arguments: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.source = source
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    /// Returns one named string argument.
    public func string(_ name: String) -> String? {
        arguments[name]
    }

    /// Returns one named boolean argument after wire-string coercion.
    public func bool(_ name: String) -> Bool? {
        guard let value = arguments[name]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        switch value {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}

/// Observable outcome returned by every action executor.
public enum CmuxActionExecutionResult: Sendable, Equatable {
    /// The action completed synchronously.
    case completed
    /// The action presented UI that owns the remaining interaction.
    case presented
    /// The caller omitted required statically declared arguments.
    case requiresArguments([CmuxActionArgumentDefinition])
    /// The caller supplied argument names that the action does not declare.
    case invalidArguments([String])
    /// The caller supplied values that do not match declared argument types.
    case invalidArgumentValues([String])
    /// The action rejected the invocation or failed to start.
    case failed(code: String, message: String)
}

/// Main-actor executor shared by command-palette and automation adapters.
public typealias CmuxActionHandler = @MainActor (CmuxActionInvocation) -> CmuxActionExecutionResult
