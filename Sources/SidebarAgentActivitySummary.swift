import CmuxSidebar
import Foundation

struct SidebarAgentActivitySummary {
    private let aggregator = SidebarAgentActivityAggregator()

    func visibleActiveCodingAgentCount(
        showsAgentActivity: Bool,
        statesByPanelId: @autoclosure () -> [UUID: [String: AgentHibernationLifecycleState]]
    ) -> Int {
        guard showsAgentActivity else { return 0 }
        return activeCodingAgentCount(statesByPanelId: statesByPanelId())
    }

    func activeCodingAgentCount(
        statesByPanelId: [UUID: [String: AgentHibernationLifecycleState]]
    ) -> Int {
        statesByPanelId.values.reduce(0) { partial, panelStates in
            partial + panelStates.values.reduce(0) { $1 == .running ? $0 + 1 : $0 }
        }
    }

    func visibleCounts(
        showsAgentActivity: Bool,
        countsByWorkspace: @autoclosure () -> [SidebarAgentActivityCounts]
    ) -> SidebarAgentActivityCounts {
        guard showsAgentActivity else { return SidebarAgentActivityCounts() }
        return aggregator.total(counts: countsByWorkspace())
    }

    func counts(
        statesByPanelId: [UUID: [String: AgentHibernationLifecycleState]]
    ) -> SidebarAgentActivityCounts {
        aggregator.counts(panelActivities: statesByPanelId.values.lazy.map { panelStates in
            var activity = SidebarAgentPanelActivity.inactive
            for (key, state) in panelStates where !AgentHibernationLifecycleStatusKeys.isManualKey(key) {
                if state == .needsInput {
                    return .needsInput
                }
                if state == .running {
                    activity = .running
                }
            }
            return activity
        })
    }

    func visibleCounts(
        showsAgentActivity: Bool,
        statesByPanelId: @autoclosure () -> [UUID: [String: AgentHibernationLifecycleState]]
    ) -> SidebarAgentActivityCounts {
        guard showsAgentActivity else { return SidebarAgentActivityCounts() }
        return counts(statesByPanelId: statesByPanelId())
    }

    func accessibilityText(counts: SidebarAgentActivityCounts) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "workspaceGroup.agentActivity.a11y",
                defaultValue: "Running agents: %1$lld. Need input: %2$lld."
            ),
            Int64(counts.running),
            Int64(counts.needsInput)
        )
    }

    func runningText(count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "workspaceGroup.agentActivity.running", defaultValue: "▶ %lld"),
            Int64(count)
        )
    }

    func needsInputText(count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "workspaceGroup.agentActivity.needsInput", defaultValue: "! %lld"),
            Int64(count)
        )
    }

    func conversationSubtitle(
        showsAgentActivity: Bool,
        hidesAllDetails: Bool,
        iMessageModeEnabled: Bool,
        message: String?
    ) -> String? {
        guard !showsAgentActivity, !hidesAllDetails, iMessageModeEnabled else { return nil }
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func notificationSubtitle(
        showsAgentActivity _: Bool,
        message: String?
    ) -> String? {
        message
    }
}
