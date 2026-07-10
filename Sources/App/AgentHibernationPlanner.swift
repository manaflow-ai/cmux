import Foundation

enum AgentHibernationPlanner {
    static func selectedPanelKeys(
        inputs: [AgentHibernationPlannerInput],
        settings: AgentHibernationSettings.Values,
        now: TimeInterval
    ) -> Set<AgentHibernationPanelKey> {
        guard settings.enabled else { return [] }
        let liveRestorable = inputs.filter { $0.hasRestorableAgent && $0.isLive }
        let excess = liveRestorable.count - settings.maxLiveTerminals
        guard excess > 0 else { return [] }

        // Live scoped processes still create cap pressure, but they are not
        // eligible for teardown; reclaim safe idle panes first instead.
        let eligible = liveRestorable
            .filter { input in
                !input.isProtected &&
                    !input.hasLiveProcess &&
                    input.lifecycle.allowsHibernation &&
                    !input.isTemporarilyUnableToProtect &&
                    !input.hasUnconfirmedTerminalInput &&
                    now - input.lastActivityAt >= settings.idleSeconds
            }
            .sorted { lhs, rhs in
                if lhs.lastActivityAt == rhs.lastActivityAt {
                    return lhs.key.panelId.uuidString < rhs.key.panelId.uuidString
                }
                return lhs.lastActivityAt < rhs.lastActivityAt
            }

        return Set(eligible.prefix(excess).map(\.key))
    }
}
