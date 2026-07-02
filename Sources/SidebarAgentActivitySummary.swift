import Foundation

enum SidebarAgentActivitySummary {
    static func activeCodingAgentCount(
        statesByPanelId: [UUID: [String: AgentHibernationLifecycleState]]
    ) -> Int {
        statesByPanelId.values.reduce(0) { partial, panelStates in
            partial + panelStates.values.reduce(0) { $1 == .running ? $0 + 1 : $0 }
        }
    }
}
