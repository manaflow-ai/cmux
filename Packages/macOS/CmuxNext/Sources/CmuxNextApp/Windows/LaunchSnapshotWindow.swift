import CmuxNextControl
import CmuxNextDaemon
import Foundation

/// The launch window drawn from the daemon's launch snapshot
/// (`launch-snapshot-v1`) before the daemon answers: the frontmost saved
/// window (frame, sidebar, shown workspace) when the snapshot has window
/// records, else one window listing every workspace of the snapshot's
/// tree. Terminals attach once connected; `WindowManager.restore` adopts
/// the same window, so the live tree replaces the snapshot in place.
struct LaunchSnapshotWindow {
    let manager: WindowManager

    /// False when the snapshot has nothing to draw (or there is none).
    func show() -> Bool {
        let daemon = manager.services.daemon
        guard daemon.store.isProvisional else { return false }
        if let document = daemon.launchSnapshotWindows, showSaved(document) { return true }
        return showEveryWorkspace(daemon.store)
    }

    private func showSaved(_ document: WindowStateDocument) -> Bool {
        let saved = WindowRegistry(records: document.windows)
        guard let front = saved.recency.first(where: { id in saved.window(id).map(manager.hasMirroredWorkspace) == true }),
              let record = document.windows.first(where: { $0.id == front }), let window = saved.window(front) else { return false }
        manager.launchWindowID = front
        manager.state(for: front).adopt(record)
        manager.registry.provisional[front] = window.workspaceIDs
        // Unregistered (no workspaces), so it is presented at once.
        manager.makeController(for: WindowRegistry.Window(id: front, frame: window.frame, display: window.display))
        DebugTimings.markLaunch("launch_snapshot_shown")
        return true
    }

    /// No window records (an older snapshot, or none saved yet): the tree
    /// still says which workspaces exist, so the launch window lists them
    /// all until the restore assigns windows.
    private func showEveryWorkspace(_ store: DaemonStore) -> Bool {
        let workspaces = store.workspaces.map(\.id)
        guard !workspaces.isEmpty else { return false }
        let id = UUID().uuidString.lowercased()
        manager.launchWindowID = id
        manager.registry.provisional[id] = workspaces
        manager.makeController(for: WindowRegistry.Window(id: id))
        DebugTimings.markLaunch("launch_snapshot_shown")
        return true
    }
}
