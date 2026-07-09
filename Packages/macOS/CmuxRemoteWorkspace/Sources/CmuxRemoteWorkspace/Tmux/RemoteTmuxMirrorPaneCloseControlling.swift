import Foundation

/// The pane-close control surface of one mirrored multi-pane tmux window, as
/// seen by ``RemoteTmuxMirrorCoordinator``.
///
/// This is the small slice of a window mirror the pane-close orchestration
/// touches: send a `kill-pane`, read the cached foreground classification, and
/// run a live close-time activity query. The live window mirror (which also owns
/// the per-pane terminal panels and AppKit rendering, hence stays in the app
/// target) conforms to this protocol so the coordinator can drive a pane close
/// without importing the UI-coupled mirror type.
///
/// `@MainActor` matches the mirror's isolation exactly: every method lifted here
/// was already a `@MainActor` method on the live window mirror.
@MainActor
public protocol RemoteTmuxMirrorPaneCloseControlling: AnyObject {
    /// Propagates a user close of `tmuxPaneId` to tmux `kill-pane`. The pane is
    /// removed via the resulting `%layout-change` (or `%window-close` if it was
    /// the window's last pane), never locally.
    func requestKillPane(_ tmuxPaneId: Int)

    /// The pane's last-known foreground classification (alt-screen flag +
    /// `pane_current_command`). `nil` when the pane was never classified (then
    /// it closes without a dialog).
    func paneForegroundState(_ tmuxPaneId: Int) -> RemoteTmuxPaneForegroundState?

    /// Live, close-time query of `tmuxPaneId`'s foreground state. Completes with
    /// `nil` when the connection is gone, so the caller falls back to
    /// ``paneForegroundState(_:)``.
    func queryPaneActivity(
        _ tmuxPaneId: Int,
        completion: @escaping ([Int: RemoteTmuxPaneForegroundState]?) -> Void
    )
}
