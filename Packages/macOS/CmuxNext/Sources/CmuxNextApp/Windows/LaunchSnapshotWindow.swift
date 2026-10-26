import CmuxNextControl
import CmuxNextDaemon
import CmuxNextLaunch
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
        let saved = WindowRegistry(records: document.windows), machines = manager.services.machines
        guard let front = Self.front(of: document.windows, mirrors: { machines.workspace(id: $0) != nil })?.id,
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
    /// all until the restore assigns windows. Never after a crash that left
    /// incognito workspaces (the ledger's launch read lists them, has not
    /// ended, or found a file it could not read): they must not appear in a normal window, and the restore discards them.
    private func showEveryWorkspace(_ store: DaemonStore) -> Bool {
        let workspaces = store.workspaces.map(\.id)
        guard !workspaces.isEmpty, !manager.incognitoLedger.mayHaveLeftovers else { return false }
        let id = UUID().uuidString.lowercased()
        manager.launchWindowID = id
        manager.registry.provisional[id] = workspaces
        manager.makeController(for: WindowRegistry.Window(id: id))
        DebugTimings.markLaunch("launch_snapshot_shown")
        return true
    }

    /// The saved window the launch shows first (``showSaved(_:)``): the front of `WindowRegistry(records:)`'s
    /// recency that keeps a workspace `mirrors` holds. Nil when none does.
    nonisolated static func front(of records: [WindowRecord], mirrors: (String) -> Bool) -> WindowRegistry.Restored? {
        WindowRegistry.restored(records).first { $0.workspaceIDs.contains(where: mirrors) }
    }

    /// The window the launch will show first from `session`'s launch snapshot, and its profile: the front
    /// window's picture is read for it in `main` (p08-startup-058). Nil without a snapshot or window records. It
    /// reads the snapshot: call it on a lane.
    nonisolated static func savedFront(session: String, stateDirectory: URL?,
                                       location: LaunchSnapshotLocation = LaunchSnapshotLocation()) -> WindowPictureStore.FrontWindow? {
        guard let path = location.path(session: session) ?? LaunchSnapshotLocation.find(session: session, in: stateDirectory),
              let snapshot = try? LaunchSnapshot.load(path: path, session: session) else { return nil }
        return savedFront(windows: snapshot.windows, tree: snapshot.tree)
    }

    /// The window ``showSaved(_:)`` shows when the provisional store holds `tree` (indexed by
    /// `WorkspaceModel.identity`, the ids the records list), and its profile.
    nonisolated static func savedFront(windows: WindowStateDocument?, tree: DaemonTree) -> WindowPictureStore.FrontWindow? {
        guard let records = windows?.windows else { return nil }
        let workspaces = Set(tree.workspaces.map { WorkspaceModel.identity($0) })
        return front(of: records, mirrors: { workspaces.contains($0) }).map { front in
            WindowPictureStore.FrontWindow(window: front.id, profile: (front.profile ?? .defaultProfile).rawValue)
        }
    }
}
