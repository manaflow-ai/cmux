import CmuxNextCompat
import CmuxNextDaemon
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
    private var observation: Task<Void, Never>?

    init(services: AppServices) {
        undoToasts = CloseUndoToasts(services: services)
        let machines = services.machines
        // task-owner: the feed (cancelled in deinit); event-driven (Observation)
        observation = Task { [weak self] in
            for await _ in ObservationStream({ Self.signature(of: machines.daemons) }) {
                self?.changes.bump()
            }
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        observation?.cancel()
    }

    /// What the feed watches, O(machines): each connected machine's tab
    /// list revision (`DaemonStore.tabListRevision`, bumped once per apply
    /// that changes its tabs, their panes or order) and closed item ids.
    private static func signature(of daemons: [DaemonService]) -> [String] {
        var parts: [String] = []
        for daemon in daemons {
            let store = daemon.store
            guard case .connected = store.connectionState, store.isLoaded else { continue }
            parts.append("\(daemon.machineID):\(store.tabListRevision)")
            parts += store.closedItems.map(\.id)
        }
        return parts
    }
}
