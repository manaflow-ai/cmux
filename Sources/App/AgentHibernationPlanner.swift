import Foundation

enum AgentHibernationReclaimTrigger: Equatable, Sendable {
    case scheduled
    case systemMemoryPressure
    case aggregateMemoryPressure

    var isMemoryPressure: Bool {
        switch self {
        case .scheduled:
            false
        case .systemMemoryPressure, .aggregateMemoryPressure:
            true
        }
    }
}

enum AgentHibernationPlanner {
    static func selectedPanelKeys(
        inputs: [AgentHibernationPlannerInput],
        settings: AgentHibernationSettings.Values,
        now: TimeInterval,
        trigger: AgentHibernationReclaimTrigger = .scheduled
    ) -> Set<AgentHibernationPanelKey> {
        Set(
            orderedPanelKeys(
                inputs: inputs,
                settings: settings,
                now: now,
                trigger: trigger
            )
        )
    }

    /// Returns pressure candidates in deterministic hibernation order.
    /// Oldest activity wins; UUID is a stable tie-breaker across dictionary and
    /// workspace traversal order.
    static func orderedPanelKeys(
        inputs: [AgentHibernationPlannerInput],
        settings: AgentHibernationSettings.Values,
        now: TimeInterval,
        trigger: AgentHibernationReclaimTrigger = .scheduled
    ) -> [AgentHibernationPanelKey] {
        let liveRestorable = inputs.filter { $0.hasRestorableAgent && $0.isLive }
        let scheduledExcess: Int?
        switch trigger {
        case .scheduled:
            guard settings.enabled else { return [] }
            scheduledExcess = liveRestorable.count - settings.maxLiveTerminals
        case .systemMemoryPressure, .aggregateMemoryPressure:
            // Memory pressure is a trigger, not a memory or agent quota.
            // Every candidate that is already idle and independently proven
            // safe may enter the ordinary lossless hibernation lifecycle.
            scheduledExcess = nil
        }
        if let scheduledExcess, scheduledExcess <= 0 { return [] }

        // The pressure signal never changes the lifecycle eligibility contract:
        // the controller confirms stability, protects the transcript, and
        // revalidates the exact process scope before any teardown.
        let eligible = liveRestorable
            .filter { input in
                !input.isProtected &&
                    input.processSafetyAllowsHibernation &&
                    input.lifecycle.allowsHibernation &&
                    !input.isTemporarilyUnableToProtect &&
                    !input.hasUnconfirmedTerminalInput &&
                    (
                        trigger.isMemoryPressure ||
                            now - input.lastActivityAt >= settings.idleSeconds
                    )
            }
            .sorted { lhs, rhs in
                if lhs.lastActivityAt == rhs.lastActivityAt {
                    if lhs.key.workspaceId != rhs.key.workspaceId {
                        return lhs.key.workspaceId.uuidString < rhs.key.workspaceId.uuidString
                    }
                    return lhs.key.panelId.uuidString < rhs.key.panelId.uuidString
                }
                return lhs.lastActivityAt < rhs.lastActivityAt
            }

        if trigger.isMemoryPressure {
            return eligible.map(\.key)
        }
        return eligible.prefix(scheduledExcess ?? 0).map(\.key)
    }
}
