import Foundation

enum SidebarAgentActivitySummary {
    static func activeCodingAgentCount(
        statesByPanelId: [UUID: [String: AgentHibernationLifecycleState]]
    ) -> Int {
        statesByPanelId.values.reduce(0) { partial, panelStates in
            partial + panelStates.values.filter { $0 == .running }.count
        }
    }
}
