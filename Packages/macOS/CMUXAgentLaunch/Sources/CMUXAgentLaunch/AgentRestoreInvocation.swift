/// The fully planned, shell-free invocation used by `cmux restore`.
public struct AgentRestoreInvocation: Equatable, Sendable {
    /// Process arguments, including `argv[0]`.
    public let arguments: [String]
    /// The working directory applied before process replacement.
    public let workingDirectory: String?
    /// The complete child environment.
    public let environment: [String: String]
    /// Typed subprocesses that must succeed before the final process replacement.
    public let preflightInvocations: [AgentRestorePreflightInvocation]
    /// Validated Codex thread requiring an ownership check at the exec boundary.
    public let codexResumeSessionID: String?

    /// Creates a planned restore invocation.
    public init(
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        preflightInvocations: [AgentRestorePreflightInvocation] = [],
        codexResumeSessionID: String? = nil
    ) {
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.preflightInvocations = preflightInvocations
        self.codexResumeSessionID = codexResumeSessionID
    }
}
