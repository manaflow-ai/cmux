/// The fully planned, shell-free invocation used by `cmux restore` or `cmux fork`.
public struct AgentRestoreInvocation: Equatable, Sendable {
    /// Process arguments, including `argv[0]`.
    public let arguments: [String]
    /// The working directory applied before process replacement.
    public let workingDirectory: String?
    /// The complete child environment.
    public let environment: [String: String]
    /// Typed subprocesses that must succeed before the final process replacement.
    public let preflightInvocations: [AgentRestorePreflightInvocation]

    /// Creates a planned restore or fork invocation.
    public init(
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        preflightInvocations: [AgentRestorePreflightInvocation] = []
    ) {
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.preflightInvocations = preflightInvocations
    }
}
