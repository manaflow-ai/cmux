import Foundation

extension TabManager {
    /// Closes a socket/API-targeted workspace without an interactive veto.
    ///
    /// Closing a window's last workspace means closing the window. A remote-tmux
    /// mirror is detached from its local owner first so a socket close never maps
    /// to the explicit remote-session kill path.
    @discardableResult
    func closeWorkspaceNonInteractively(_ workspace: Workspace, recordHistory: Bool = true) -> Bool {
        guard canCloseWorkspace(workspace),
              tabs.contains(where: { $0.id == workspace.id }) else { return false }
        guard tabs.count == 1 else {
            closeWorkspace(workspace, recordHistory: recordHistory)
            return !tabs.contains(where: { $0.id == workspace.id })
        }
        guard let appDelegate = AppDelegate.shared,
              let windowId = appDelegate.windowId(for: self),
              appDelegate.mainWindow(for: windowId) != nil else { return false }
        if workspace.isRemoteTmuxMirror {
            appDelegate.remoteTmuxController.detachMirrorWorkspaceKeptOpenLocally(workspaceId: workspace.id)
        }
        return appDelegate.closeMainWindow(windowId: windowId, recordHistory: recordHistory)
    }
}
