/// The authoritative facts available when an agent command returns to its shell.
public struct AgentSessionRetryContext: Equatable, Sendable {
    /// Whether the user opted into automatic retry.
    public let isEnabled: Bool
    /// Whether managed hooks observed an active agent during this command.
    public let hadActiveAgentSession: Bool
    /// Whether cmux retained a managed resume binding for the active session.
    public let hasManagedResumeBinding: Bool
    /// The shell-reported exit status, or `nil` when shell integration omitted it.
    public let exitCode: Int?

    /// Creates the facts used to classify one command termination.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether the user opted into automatic retry.
    ///   - hadActiveAgentSession: Whether managed hooks observed an active agent.
    ///   - hasManagedResumeBinding: Whether the active session can be resumed.
    ///   - exitCode: The shell-reported exit status, or `nil` when unavailable.
    public init(
        isEnabled: Bool,
        hadActiveAgentSession: Bool,
        hasManagedResumeBinding: Bool,
        exitCode: Int?
    ) {
        self.isEnabled = isEnabled
        self.hadActiveAgentSession = hadActiveAgentSession
        self.hasManagedResumeBinding = hasManagedResumeBinding
        self.exitCode = exitCode
    }
}
