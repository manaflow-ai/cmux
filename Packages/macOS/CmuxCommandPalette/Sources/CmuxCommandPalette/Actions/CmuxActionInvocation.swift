import Foundation

/// One invocation of a statically defined cmux action.
public struct CmuxActionInvocation: Sendable, Equatable {
    /// Adapter that initiated the invocation.
    public let source: CmuxActionInvocationSource
    /// Named argument values supplied by the adapter.
    public let arguments: [String: String]
    /// Caller working directory used to resolve relative `path` arguments.
    public let workingDirectory: String?

    /// Creates an action invocation.
    ///
    /// - Parameters:
    ///   - source: The adapter initiating the action.
    ///   - arguments: Named argument values supplied by the adapter.
    ///   - workingDirectory: Caller directory used to resolve relative paths.
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
