import CmuxNextDaemonService
import CmuxNextUpdater
import CmuxNextWindowRules

/// Update When Idle (`updates.installWhenIdle`, off by default; Leo, 2026-11-19: "when it's idle, it's able to ...
/// update automatically ... maybe even having it as an opt-in option would be pretty interesting"). The
/// updater's automatic-install hold asks this once a second while a staged update waits; the rule is Rust's
/// (cmux-window-rules `update_idle`). This reads the facts only: the input time first, and this Mac's agent
/// turns and drafts only once the person has been away long enough, so a person at the Mac costs no
/// acpmux read.
extension UpdaterService {
    func attachIdleGate(services: AppServices, activity: UpdateAgentActivity) {
        idleInstallGate = { [weak self, weak services, activity] in
            guard let self, let services, let window = self.installWhenIdle else { return .unknown }
            let rules = WindowRules()
            var facts = WindowRules.UpdateIdleFacts(enabled: true, idleMinutes: window / .seconds(60),
                                                    inputIdleSeconds: DaemonService.secondsSinceInput())
            // The idle time first: while the person is at the Mac nothing else is read.
            if case .notIdle? = rules.updateIdleHold(facts) { return .notIdle }
            let blockers = activity.applying(to: services.machines.local.currentRelaunchBlockers(quietInput: nil))
            if let census = activity.census, !blockers.daemonStateUnavailable {
                // The app's chats (the tab mirror) and every turn of this Mac's acpmux, the Chief's included.
                facts.runningTurns = max(blockers.busyAgentCount, census.inTurn + (census.chiefInTurn ? 1 : 0))
                facts.unsentDrafts = census.drafts + services.agentTabs.unsentDrafts.count
            }
            return switch rules.updateIdleHold(facts) {
            case nil: nil
            case .notIdle?: .notIdle
            case .agentWorking?: .agentWorking
            case .unsentDraft?: .unsentDraft
            case .off?, .unknown?: .unknown
            }
        }
    }
}
