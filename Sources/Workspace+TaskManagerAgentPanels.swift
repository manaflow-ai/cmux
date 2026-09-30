import Foundation

extension Workspace {
    /// One `agent_panels` entry per terminal that has a coding agent state:
    /// the aggregated lifecycle the sidebar and hibernation use, the sidebar
    /// status text, and when that state was entered. Hibernated agents are
    /// reported too, since they have no process for the sampler to find.
    func taskManagerAgentPanelPayloads() -> [[String: Any]] {
        var payloads: [[String: Any]] = []
        for panelId in panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let terminalPanel = terminalPanel(for: panelId) else { continue }
            if terminalPanel.isAgentHibernated, let state = terminalPanel.agentHibernationState {
                payloads.append([
                    "workspace_id": id.uuidString,
                    "surface_id": panelId.uuidString,
                    "state": "hibernated",
                    "since": Workspace.taskManagerTimestamp(state.hibernatedAt),
                    "agent_name": state.agentDisplayName,
                    "agent_id": state.agent.kind.rawValue
                ])
                continue
            }
            // Same reduction agent hibernation uses, so
            // overlay keys such as a Feed permission prompt count too; only
            // `cmux workspace loading` manual keys are left out.
            let hasAgentLifecycle = (agentLifecycleStatesByPanelId[panelId] ?? [:]).keys
                .contains { !AgentHibernationLifecycleStatusKeys.isManualKey($0) }
            let status = mobileAgentStatus(forPanel: panelId)
            guard hasAgentLifecycle || status != nil else { continue }
            let lifecycle = agentHibernationLifecycleState(panelId: panelId, fallback: nil)
            payloads.append([
                "workspace_id": id.uuidString,
                "surface_id": panelId.uuidString,
                "state": lifecycle.rawValue,
                "status_text": status?.state as Any? ?? NSNull(),
                "since": taskManagerAgentStateSince(panelId: panelId, statusKey: status?.source)
                    .map(Workspace.taskManagerTimestamp) as Any? ?? NSNull()
            ])
        }
        return payloads
    }

    /// The last lifecycle transition hibernation tracking recorded, else the
    /// time the winning sidebar status entry was reported.
    private func taskManagerAgentStateSince(panelId: UUID, statusKey: String?) -> Date? {
        let key = AgentHibernationPanelKey(workspaceId: id, panelId: panelId)
        if let changedAt = AgentHibernationController.shared.lifecycleChangeByPanel[key], changedAt > 0 {
            return Date(timeIntervalSince1970: changedAt)
        }
        return statusKey.flatMap { statusEntries[$0]?.timestamp }
    }

    private static func taskManagerTimestamp(_ date: Date) -> String {
        taskManagerTimestampFormatter.string(from: date)
    }

    private static let taskManagerTimestampFormatter = ISO8601DateFormatter()
}
