import Foundation

enum SidebarAgentActivitySummary {
    static func visibleActiveCodingAgentCount(
        showsAgentActivity: Bool,
        statesByPanelId: @autoclosure () -> [UUID: [String: AgentHibernationLifecycleState]]
    ) -> Int {
        guard showsAgentActivity else { return 0 }
        return activeCodingAgentCount(statesByPanelId: statesByPanelId())
    }

    static func visibleActiveCodingAgentCount(
        showsAgentActivity: Bool,
        recordsByPanelId: @autoclosure () -> [UUID: [String: AgentLifecycleRecord]]
    ) -> Int {
        guard showsAgentActivity else { return 0 }
        return recordsByPanelId().values.reduce(0) { partial, panelRecords in
            partial + panelRecords.values.reduce(0) {
                $1.state == .running ? $0 + 1 : $0
            }
        }
    }

    static func activeCodingAgentCount(
        statesByPanelId: [UUID: [String: AgentHibernationLifecycleState]]
    ) -> Int {
        statesByPanelId.values.reduce(0) { partial, panelStates in
            partial + panelStates.values.reduce(0) { $1 == .running ? $0 + 1 : $0 }
        }
    }
}
