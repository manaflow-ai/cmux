import Foundation

/// Immutable agent-lifecycle projection shared by mobile payloads and change detection.
struct MobileWorkspaceAgentStatusSnapshot: Equatable, Sendable {
    let agent: String
    let state: AgentHibernationLifecycleState
    let panelIDs: [UUID]

    var payload: [String: Any] {
        [
            "agent": agent,
            "state": Self.wireState(state),
            "panel_ids": panelIDs.map(\.uuidString),
        ]
    }

    func combine(into hasher: inout Hasher) {
        hasher.combine(agent)
        hasher.combine(state.rawValue)
        hasher.combine(panelIDs)
    }

    @MainActor
    static func capture(workspace: Workspace) -> [Self] {
        let validPanelIDs = Set(workspace.panels.keys)
        var stateByAgent: [String: AgentHibernationLifecycleState] = [:]
        var panelIDsByAgent: [String: Set<UUID>] = [:]

        for (panelID, states) in workspace.agentLifecycleStatesByPanelId where validPanelIDs.contains(panelID) {
            for (agent, state) in states where !AgentHibernationLifecycleStatusKeys.isManualKey(agent) {
                panelIDsByAgent[agent, default: []].insert(panelID)
                if let current = stateByAgent[agent], priority(current) >= priority(state) {
                    continue
                }
                stateByAgent[agent] = state
            }
        }

        return stateByAgent.keys.sorted().compactMap { agent in
            guard let state = stateByAgent[agent] else { return nil }
            let panelIDs = (panelIDsByAgent[agent] ?? []).sorted { $0.uuidString < $1.uuidString }
            return Self(agent: agent, state: state, panelIDs: panelIDs)
        }
    }

    private static func priority(_ state: AgentHibernationLifecycleState) -> Int {
        switch state {
        case .needsInput: return 4
        case .running: return 3
        case .idle: return 2
        case .unknown: return 1
        }
    }

    private static func wireState(_ state: AgentHibernationLifecycleState) -> String {
        switch state {
        case .needsInput: return "needs_input"
        case .running, .idle, .unknown: return state.rawValue
        }
    }
}
