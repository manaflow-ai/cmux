/// Why automatic retry deliberately declined a command termination.
public enum AgentSessionRetryRejection: Equatable, Sendable {
    /// Automatic retry is disabled.
    case disabled
    /// No managed agent was active when the command ended.
    case inactiveSession
    /// The active session has no authoritative managed resume binding.
    case missingResumeBinding
    /// Shell integration did not report an exit status.
    case unknownExit
    /// The command completed successfully.
    case successfulExit
    /// The exit status is signal-like and may represent an intentional stop.
    case signalExit
}
