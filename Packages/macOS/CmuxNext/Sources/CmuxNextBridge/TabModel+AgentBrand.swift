import CmuxAgentBrands
import CmuxNextDaemon

extension TabModel {
    /// The brand id (design/agent-icons) of what runs in the tab: an agent chat's harness,
    /// else the agent a hook reported in a live terminal until its session ends (cx-ag5.3).
    package var agentBrand: String? {
        if let harness = agentSession?.harness { return AgentBrandCatalog.brand(for: harness)?.rawValue }
        guard !dead, let agent, agent.state != .done else { return nil }
        return AgentBrandCatalog.brand(for: agent.agent)?.rawValue
    }

    /// The name of that agent ("Claude Code", "Codex"), or nil when cmux does not list it.
    package var agentName: String? {
        let id = agentSession?.harness ?? (dead || agent?.state == .done ? nil : agent?.agent)
        return id.flatMap { id in AgentBrandCatalog.agents.first { $0.id == id.lowercased() }?.name }
    }
}
