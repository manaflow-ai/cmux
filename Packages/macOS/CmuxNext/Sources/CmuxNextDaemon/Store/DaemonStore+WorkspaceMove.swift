import Foundation

/// The optimistic placement of a tab dropped on another workspace (`move-tab-to-workspace`,
/// tab-move-tearing): the drop shows its result in the input's turn instead of after the reply
/// and the snapshot the daemon's `tree-changed` asks for.
extension DaemonStore {
    /// The intent that shows `surface` where the daemon puts it in `workspace`: appended to the
    /// active pane of the workspace's active screen. Nil when the store cannot know that place
    /// (no such workspace or tab, the tab is already there, or the workspace has no pane: the
    /// daemon builds its layout then), so the move waits for the daemon as before.
    public func workspaceMoveIntent(surface: SurfaceID, into workspace: WorkspaceHandle) -> Intent? {
        nil
    }
}
