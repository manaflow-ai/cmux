import CmuxNextControl
import CmuxNextDaemon

// The launch snapshot (`launch-snapshot-v1`): the first window drawn from the
// daemon's last settled tree and window records, before it answers.
extension WindowManager {
    /// Draws the frontmost saved window from the daemon's launch snapshot
    /// (`DaemonService.launchSnapshotWindows`, applied to the store as a
    /// provisional tree) before the daemon answers: its frame, sidebar and
    /// shown workspace, with terminals attaching once connected. The window
    /// is the launch window; `restore` adopts the same record, so the live
    /// tree replaces the snapshot in place. False when there is nothing to
    /// draw.
    func showLaunchSnapshot() -> Bool {
        guard services.daemon.store.isProvisional, let document = services.daemon.launchSnapshotWindows else { return false }
        let saved = WindowRegistry(records: document.windows)
        guard let front = saved.recency.first(where: { id in saved.window(id).map(hasMirroredWorkspace) == true }),
              let record = document.windows.first(where: { $0.id == front }), let window = saved.window(front) else { return false }
        launchWindowID = front
        state(for: front).adopt(record)
        registry.provisional[front] = window.workspaceIDs
        // Unregistered (no workspaces), so it is presented at once.
        makeController(for: WindowRegistry.Window(id: front, frame: window.frame, display: window.display))
        DebugTimings.markLaunch("launch_snapshot_shown")
        return true
    }
}
