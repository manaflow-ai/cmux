/// How a compact-and-resume run ended.
public enum AgentCompactResumeOutcome: Sendable, Equatable {
    /// The context was compacted and the continue prompt was sent.
    case resumed
    /// The run stopped without typing anything further.
    case stopped(AgentCompactResumeStopReason)
}
