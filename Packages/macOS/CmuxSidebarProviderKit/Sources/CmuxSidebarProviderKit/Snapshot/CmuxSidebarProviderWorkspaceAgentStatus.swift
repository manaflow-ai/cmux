/// Structured agent status exposed to in-process sidebar providers.
public enum CmuxSidebarProviderWorkspaceAgentStatus: String, Codable, Equatable, Sendable {
    /// The host knows an agent exists, but does not know whether it is active or idle.
    case unknown
    /// At least one agent is currently running work.
    case running
    /// The agent is idle and can be treated as not actively needing attention.
    case idle
    /// The agent is waiting for user input.
    case needsInput
}
