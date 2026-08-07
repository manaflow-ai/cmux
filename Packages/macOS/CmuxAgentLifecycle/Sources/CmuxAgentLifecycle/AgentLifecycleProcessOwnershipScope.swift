/// Defines which lifecycle identity owns an integration's agent process.
public nonisolated enum AgentLifecycleProcessOwnershipScope: Hashable, Sendable {
    /// Each session owns a distinct agent process generation.
    case session
    /// Multiple sessions share one long-lived agent process generation.
    case sharedProcess
}
