import CmuxTerminal
import Foundation

enum AgentHibernationReclaimTrigger: Equatable, Sendable {
    case scheduled
    case systemMemoryPressure
    /// User asked for these exact panels to sleep. Unlike the other triggers
    /// this carries its own selection, so the planner does not choose victims:
    /// it confirms the request is still safe to act on.
    case manual(Set<AgentHibernationPanelKey>)

    var isManual: Bool {
        if case .manual = self { return true }
        return false
    }
}

enum AgentHibernationPlanner {
    static func selectedPanelKeys(
        inputs: [AgentHibernationPlannerInput],
        settings: AgentHibernationSettings.Values,
        now: TimeInterval,
        trigger: AgentHibernationReclaimTrigger = .scheduled
    ) -> Set<AgentHibernationPanelKey> {
        let liveRestorable = inputs.filter { $0.hasRestorableAgent && $0.isLive }
        let excess: Int
        switch trigger {
        case .scheduled:
            guard settings.enabled else { return [] }
            excess = liveRestorable.count - settings.maxLiveTerminals
        case .systemMemoryPressure:
            // Snapshot and reclaim a small batch before the next pressure pass.
            excess = min(
                liveRestorable.count,
                TerminalSurfaceRuntimeTeardownCoordinator
                    .maximumIsolatedHibernationTeardownCount
            )
        case .manual(let requestedKeys):
            // The user named these panels, so none of the routine gates apply:
            // not the enabled flag, not `maxLiveTerminals`, not `idleSeconds`,
            // and not `isProtected` (that means "currently visible", which is
            // the common case when someone sleeps the pane in front of them).
            // The transcript-protection marker is the one gate kept, because it
            // signals cmux could not snapshot the agent transcript and tearing
            // down anyway risks losing it.
            return Set(
                liveRestorable
                    .filter { requestedKeys.contains($0.key) && !$0.isTemporarilyUnableToProtect }
                    .map(\.key)
            )
        }
        guard excess > 0 else { return [] }

        // Scheduled hibernation never reaps a live scoped process. Critical
        // pressure may select one only while its lifecycle is explicitly idle;
        // the controller still confirms stability, protects the transcript,
        // and revalidates the exact process set before teardown.
        let eligible = liveRestorable
            .filter { input in
                !input.isProtected &&
                    (
                        trigger == .systemMemoryPressure ||
                            !input.hasLiveProcess
                    ) &&
                    input.lifecycle.allowsHibernation &&
                    !input.isTemporarilyUnableToProtect &&
                    !input.hasUnconfirmedTerminalInput &&
                    (
                        trigger == .systemMemoryPressure ||
                            now - input.lastActivityAt >= settings.idleSeconds
                    )
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
