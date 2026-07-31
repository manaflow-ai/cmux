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
        let remoteHistoryEntry = recordHistory && workspace.isRemoteTmuxMirror
            ? appDelegate.remoteTmuxController.closedMirrorHistoryEntry(
                workspaceId: workspace.id,
                windowId: windowId,
                workspaceIndex: 0
            )
            : nil
        if workspace.isRemoteTmuxMirror {
            appDelegate.remoteTmuxController.detachMirrorWorkspaceKeptOpenLocally(workspaceId: workspace.id)
            if let remoteHistoryEntry {
                ClosedItemHistoryStore.shared.pushRemoteTmuxMirror(remoteHistoryEntry)
            }
        }
        guard appDelegate.closeMainWindow(windowId: windowId, recordHistory: recordHistory) else {
            return false
        }
        // Window unregister briefly records a recoverable route because the terminal
        // surface registry still contains this workspace's surfaces. Its unregister
        // notification retires routes on a later MainActor turn; this close is final,
        // so retire the route synchronously after capturing the close snapshot.
        workspace.withClosedPanelHistorySuppressed {
            workspace.teardownAllPanels()
        }
        workspace.teardownRemoteConnection()
        workspace.owningTabManager = nil
        appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
        return true
    }
}
