import AppKit

extension AppDelegate {
    /// Handles the `markWorkspaceDone` shortcut: resolves the TabManager for
    /// the preferred/key window (multi-window users act on the window they
    /// are looking at, mirroring `handleGroupSelectedWorkspacesShortcut`) and
    /// pins the selected workspace's todo status to done through the shared
    /// action path used by the context menu and command palette.
    ///
    /// - Returns: Whether the event was consumed (a workspace was resolved).
    func handleMarkWorkspaceDoneShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let resolvedTabManager = contextForMainWindow(targetWindow)?.tabManager ?? tabManager
        guard let workspace = resolvedTabManager?.selectedWorkspace else { return false }
        WorkspaceTodoActions.applyStatusOverride(.done, to: [workspace])
        return true
    }
}
