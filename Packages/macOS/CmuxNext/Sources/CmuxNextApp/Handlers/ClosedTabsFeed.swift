import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

/// The app side of closed tabs. The daemon owns the closed history
/// (`closed-history-v2`, `DaemonClosedHistory`); the app keeps no copy
/// (reopen-closed.md 1 and 9, deletion rule). This feed only signals Search
/// Tabs and the control snapshot after a connected machine's tabs or its
/// closed items changed, and holds the undo toasts of user closes.
@MainActor
final class ClosedTabsFeed {
    /// Bumps after every change to the mirrored tabs or the closed items:
    /// observers read the mirror and the closed list together.
    let changes = ClosedTabChanges()
    /// Undo toasts for the tabs the user closes (REOPEN-CLOSED).
    let undoToasts: CloseUndoToasts
    /// Follows each machine's revisions; released with the feed. A service observation: Search Tabs
    /// and the control snapshot read `changes` whether or not anything shows them.
    private var observation: ServiceObservation<[String]>?

    init(services: AppServices) {
        undoToasts = CloseUndoToasts(services: services)
        let machines = services.machines
        observation = ServiceObservation(.visible, owner: "ClosedTabsFeed.changes", on: services.mainWork) {
            Self.signature(of: machines.daemons)
        } apply: { [weak self] _ in
            self?.changes.bump()
        }
    }

    /// What the feed watches, O(machines): each connected machine's tab
    /// list revision (`DaemonStore.tabListRevision`, bumped once per apply
    /// that changes its tabs, their panes or order) and closed list revision
    /// (`SessionStateStore.closedRevision`, bumped once per change of its closed items).
    private static func signature(of daemons: [DaemonService]) -> [String] {
        daemons.compactMap { daemon in
            let store = daemon.store
            guard case .connected = store.connectionState, store.isLoaded else { return nil }
            return "\(daemon.machineID):\(store.tabListRevision):\(store.session.closedRevision)"
        }
    }
}
