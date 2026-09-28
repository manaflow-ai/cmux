import CmuxSidebar
import Foundation

extension Notification.Name {
    /// Posted by a `TerminalPanel` when it enters or leaves agent hibernation.
    static let terminalPanelAgentHibernationDidChange = Notification.Name(
        "cmux.terminalPanelAgentHibernationDidChange"
    )
}

extension Workspace {
    static let agentHibernatedStatusKey = "agent.hibernated"

    /// Terminal panels in this workspace whose agent is hibernated.
    var hibernatedAgentPanelCount: Int {
        panels.values.reduce(0) { count, panel in
            count + (((panel as? TerminalPanel)?.agentHibernationPhase.isSettledHibernation == true) ? 1 : 0)
        }
    }

    /// Keeps the sidebar row that says this workspace has hibernated agents in
    /// step with its panels. The row is calm on purpose: hibernation is not an
    /// error and needs no action until the user opens the pane.
    func refreshAgentHibernationStatusEntry() {
        let count = hibernatedAgentPanelCount
        guard count > 0 else {
            if statusEntries[Self.agentHibernatedStatusKey] != nil {
                statusEntries.removeValue(forKey: Self.agentHibernatedStatusKey)
            }
            return
        }
        let value = count == 1
            ? String(localized: "sidebar.status.agentHibernated.one", defaultValue: "Agent hibernated")
            : String(
                format: String(
                    localized: "sidebar.status.agentHibernated.other",
                    defaultValue: "%ld agents hibernated"
                ),
                locale: .current,
                count
            )
        if statusEntries[Self.agentHibernatedStatusKey]?.value == value { return }
        statusEntries[Self.agentHibernatedStatusKey] = SidebarStatusEntry(
            key: Self.agentHibernatedStatusKey,
            value: value,
            icon: "moon.zzz",
            color: nil,
            priority: -10,
            timestamp: Date()
        )
    }
}
