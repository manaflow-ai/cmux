/// A shell-free subprocess invocation run before the restored process.
public struct AgentRestorePreflightInvocation: Equatable, Sendable {
    /// The executable token from ``arguments``.
    public let executable: String
    /// Process arguments, including `argv[0]`.
    public let arguments: [String]
    /// Environment passed to the preflight process.
    public let environment: [String: String]

    /// Creates a preflight invocation when `arguments` contains `argv[0]`.
    ///
    /// - Parameters:
    ///   - arguments: Process arguments beginning with the executable token.
    ///   - environment: The complete environment for the preflight process.
    /// - Returns: `nil` when `arguments` is empty.
    public init?(arguments: [String], environment: [String: String]) {
        guard let executable = arguments.first else { return nil }
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}
