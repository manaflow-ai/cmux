import CmuxNextActions
import CmuxNextHistory
import CmuxNextWindowRules
import Foundation

/// Strict tab history (Rex's Go Back One Tab and Go to Recent Tab, any workspace or this one): the
/// rules are cmux-window-rules `tab_history`; the app records each settled tab and shows the step's
/// target. Apart from the location trail, so `navigation.history.scope` does not merge a
/// workspace's tabs into one step and the workspace scope admits no top page or other workspace.
extension LocationTrailService {
    /// The active window settled on `location` (a tab; top pages are not tab visits).
    func recordTab(_ location: HistoryLocation) {
        guard location.page == nil else { return }
        let visit = TabHistory.Visit(tab: location.key.tab, workspace: location.workspace, machine: location.key.machine)
        currentTab = visit
        if let reply = WindowRules().tabHistory(tabHistory, record: visit) { tabHistory = reply.history }
    }

    /// Shows the tab `step` reaches within `scope`; false when there is nowhere to go. A tab that
    /// can no longer be shown leaves the history and the step looks again.
    func stepTab(_ step: TabHistory.Step, scope: TabHistory.Scope) -> Bool {
        guard ActionRunScope.viewChangeAllowed(), let current = currentTab else { return false }
        let rules = WindowRules()
        for _ in 0..<8 {
            guard let reply = rules.tabHistory(tabHistory, step: step, scope: scope, current: current) else { return false }
            tabHistory = reply.history
            guard let target = reply.target else { return false }
            if services.revealTab(target.tab) { return true }
            guard let forgot = rules.tabHistory(tabHistory, forget: target.tab) else { return false }
            tabHistory = forgot.history
        }
        return false
    }
}
