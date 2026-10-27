import CmuxNextDaemon
import CmuxNextDaemonService

/// One pane's share of a tab close, after its local half ran
/// (`PaneController.prepareClose`): the daemon tabs it closes, the commands
/// that close them one by one, and what the pane does once the daemon
/// answered. A gesture over several panes sends every pane's tabs in one
/// batch (`PaneController.close(_:)`), so the daemon stores one closed group.
@MainActor
struct PreparedTabClose {
    /// The daemon tabs this pane closes.
    var surfaces: [SurfaceID]
    /// One close command per tab, for a daemon without `batch-close-v1`.
    var commands: [DaemonService.CloseRun]
    /// Settles the pane after the daemon's answer: whether the close failed,
    /// and whether it missed its deadline.
    var finish: @MainActor (_ failed: Bool, _ unknown: Bool) async -> Void
}
