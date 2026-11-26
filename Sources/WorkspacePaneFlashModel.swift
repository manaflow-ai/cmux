import Foundation
import Observation

extension Notification.Name {
    /// Posted after a workspace pane attention flash changes. The window
    /// overlay observes this separately from geometry so a flash-only event
    /// cannot wait for an unrelated layout refresh.
    static let workspacePaneFlashDidChange = Notification.Name(
        "cmux.workspacePaneFlashDidChange"
    )
}

/// The workspace's latest pane attention flash, drawn by the window's
/// workspace pane overlay when the tmux overlay experiment targets bonsplit
/// panes.
///
/// Observable so ``TmuxWorkspacePaneOverlayRefresher`` rebuilds the overlay
/// for each flash. The flash used to be three `@Published` properties on
/// `Workspace`, which invalidated every view observing the workspace while
/// the overlay itself only picked the flash up on the window's next update.
@Observable
final class WorkspacePaneFlashModel {
    /// The panel whose pane flashes, or `nil` before the first flash.
    private(set) var panelId: UUID?
    /// Why the latest flash was requested.
    private(set) var reason: WorkspaceAttentionFlashReason?
    /// Incremented by each flash, so a repeat flash of the same panel for
    /// the same reason still starts a new animation.
    private(set) var token: UInt64 = 0

    /// Records a flash of `panelId`'s pane.
    func trigger(panelId: UUID, reason: WorkspaceAttentionFlashReason) {
        self.panelId = panelId
        self.reason = reason
        token &+= 1
    }
}
