import CmuxSidebar
import Foundation

extension Workspace {
    /// The agent status shown for one terminal pane, as the mobile plane reports
    /// it: the freshest structured status entry among the agents whose PIDs
    /// resolve to that pane (the same winner the sidebar's status row picks).
    /// `source` is the status key (`claude_code`, `codex`, …), `state` its text.
    func mobileAgentStatus(forPanel panelID: UUID) -> (source: String, state: String)? {
        var winner: SidebarStatusEntry?
        for (pidKey, ownerPanelID) in agentPIDPanelIdsByKey where ownerPanelID == panelID {
            let statusKey = agentStatusKey(forAgentPIDKey: pidKey)
            guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey),
                  let entry = statusEntries[statusKey] else { continue }
            if let current = winner {
                if current.timestamp < entry.timestamp
                    || (current.timestamp == entry.timestamp && current.priority < entry.priority)
                    || (current.timestamp == entry.timestamp && current.priority == entry.priority && entry.key < current.key) {
                    winner = entry
                }
            } else {
                winner = entry
            }
        }
        guard let winner else { return nil }
        let state = winner.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.isEmpty else { return nil }
        return (winner.key, state)
    }
}
