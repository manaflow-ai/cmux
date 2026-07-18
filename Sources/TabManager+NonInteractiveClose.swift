import Foundation

extension TabManager {
    /// Closes a socket/API-targeted workspace without an interactive veto.
    ///
    /// Closing a window's last workspace means closing the window. A remote-tmux
    /// mirror is detached from its local owner first so a socket close never maps
    /// to the explicit remote-session kill path.
    @discardableResult
    func closeWorkspaceNonInteractively(
        _ workspace: Workspace,
        recordHistory: Bool = true,
        allowPinned: Bool = false
    ) -> Bool {
        guard canCloseWorkspace(workspace, allowPinned: allowPinned),
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
        guard appDelegate.closeMainWindow(windowId: windowId, recordHistory: recordHistory) else {
            return false
        }
        // Window unregister temporarily retains a recoverable route while any
        // terminal surfaces remain registered. A noninteractive last-workspace
        // close is final, so tear down those surfaces after the close snapshot is
        // captured; the terminal registry then retires the route instead of
        // leaving a scriptable, unclosable window behind (#7992).
        workspace.withClosedPanelHistorySuppressed {
            workspace.teardownAllPanels()
        }
        workspace.teardownRemoteConnection()
        workspace.owningTabManager = nil
        return true
    }
}
