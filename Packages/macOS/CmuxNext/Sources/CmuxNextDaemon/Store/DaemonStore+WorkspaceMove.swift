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
        guard let destination = self.workspace(handle: workspace), let source = pane(containing: surface),
              self.workspace(containing: source.handle) !== destination,
              let screen = destination.screens.first(where: \.isActive) ?? destination.screens.first,
              let landing = screen.panes.first(where: { $0.handle == screen.defaultPane }) ?? screen.panes.first,
              landing.handle != source.handle else { return nil }
        return .moveTab(surface: surface, toPane: landing.handle, index: landing.tabs.count)
    }
}
