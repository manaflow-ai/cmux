/// Structured agent status exposed to in-process sidebar providers.
public enum CmuxSidebarProviderWorkspaceAgentStatus: String, Codable, Equatable, Sendable {
    case unknown
    case running
    case idle
    case needsInput
}
