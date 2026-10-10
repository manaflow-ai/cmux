import CmuxAgentBrands
import CmuxNextDaemon

extension TabModel {
    /// The brand id (design/agent-icons) of what runs in the tab: an agent chat's harness,
    /// else the agent a hook reported in a live terminal until its session ends (cx-ag5.3).
    var agentBrand: String? {
        if let harness = agentSession?.harness { return AgentBrandCatalog.brand(for: harness)?.rawValue }
        guard !dead, let agent, agent.state != .done else { return nil }
        return AgentBrandCatalog.brand(for: agent.agent)?.rawValue
    }
}
