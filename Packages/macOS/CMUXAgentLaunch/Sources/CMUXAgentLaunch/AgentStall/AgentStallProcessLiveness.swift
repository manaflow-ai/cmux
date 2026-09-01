/// Process evidence required before a managed-agent stall action can run.
public enum AgentStallProcessLiveness: Equatable, Sendable {
    /// The bound managed-agent process is confirmed alive.
    case running
    /// The bound managed-agent process is confirmed to have exited.
    case exited
    /// Available process evidence is inconclusive.
    case unknown
}
