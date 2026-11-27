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
        guard WorkspaceTodoFeature.isEnabled else { return false }
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let resolvedTabManager = contextForMainWindow(targetWindow)?.tabManager ?? tabManager
        guard let workspace = resolvedTabManager?.selectedWorkspace else { return false }
        WorkspaceTodoActions.applyStatusOverride(.done, to: [workspace])
        return true
    }

    /// Handles the `cycleWorkspaceStatus` shortcut: resolves the TabManager
    /// for the preferred/key window and advances the selected workspace's
    /// todo status one lane forward through the shared action path (same as
    /// the `workspace.status.cycle` socket verb and `cmux workspace status
    /// cycle`).
    ///
    /// - Returns: Whether the event was consumed (a workspace was resolved).
    func handleCycleWorkspaceStatusShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        guard WorkspaceTodoFeature.isEnabled else { return false }
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let resolvedTabManager = contextForMainWindow(targetWindow)?.tabManager ?? tabManager
        guard let workspace = resolvedTabManager?.selectedWorkspace else { return false }
        WorkspaceTodoActions.cycleStatus(for: workspace)
        return true
    }
}
