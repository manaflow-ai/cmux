import Foundation

enum SidebarAgentActivitySummary {
    struct Counts: Equatable, Hashable, Sendable {
        var running = 0
        var needsInput = 0

        static func + (lhs: Self, rhs: Self) -> Self {
            Self(
                running: lhs.running + rhs.running,
                needsInput: lhs.needsInput + rhs.needsInput
            )
        }
    }

    static func visibleActiveCodingAgentCount(
        showsAgentActivity: Bool,
        statesByPanelId: @autoclosure () -> [UUID: [String: AgentHibernationLifecycleState]]
    ) -> Int {
        guard showsAgentActivity else { return 0 }
        return activeCodingAgentCount(statesByPanelId: statesByPanelId())
    }

    static func activeCodingAgentCount(
        statesByPanelId: [UUID: [String: AgentHibernationLifecycleState]]
    ) -> Int {
        statesByPanelId.values.reduce(0) { partial, panelStates in
            partial + panelStates.values.reduce(0) { $1 == .running ? $0 + 1 : $0 }
        }
    }

    static func visibleCounts(
        showsAgentActivity: Bool,
        countsByWorkspace: @autoclosure () -> [Counts]
    ) -> Counts {
        guard showsAgentActivity else { return Counts() }
        return countsByWorkspace().reduce(Counts(), +)
    }

    static func counts(
        statesByPanelId: [UUID: [String: AgentHibernationLifecycleState]]
    ) -> Counts {
        statesByPanelId.values.reduce(Counts()) { partial, panelStates in
            let states = panelStates
                .filter { !AgentHibernationLifecycleStatusKeys.isManualKey($0.key) }
                .map(\.value)
            var result = partial
            if states.contains(.needsInput) {
                result.needsInput += 1
            } else if states.contains(.running) {
                result.running += 1
            }
            return result
        }
    }

    static func visibleCounts(
        showsAgentActivity: Bool,
        statesByPanelId: @autoclosure () -> [UUID: [String: AgentHibernationLifecycleState]]
    ) -> Counts {
        guard showsAgentActivity else { return Counts() }
        return counts(statesByPanelId: statesByPanelId())
    }

    static func accessibilityText(counts: Counts) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "workspaceGroup.agentActivity.a11y",
                defaultValue: "Running agents: %1$lld. Need input: %2$lld."
            ),
            Int64(counts.running),
            Int64(counts.needsInput)
        )
    }

    static func conversationSubtitle(
        showsAgentActivity: Bool,
        hidesAllDetails: Bool,
        iMessageModeEnabled: Bool,
        message: String?
    ) -> String? {
        guard !showsAgentActivity, !hidesAllDetails, iMessageModeEnabled else { return nil }
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
