import CmuxWorkspaces

/// Exact token/process generation represented by one sidebar observation.
enum SidebarAgentActivityGeneration: Equatable, Hashable, Sendable {
    case session(String)
    case process(AgentPIDProcessIdentity)
    case lifecycle
}
