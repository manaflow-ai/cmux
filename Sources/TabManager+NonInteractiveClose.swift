import Foundation

extension TabManager {
    var needsAutosavingNoteFlush: Bool {
        tabs.contains(where: \.needsAutosavingNoteFlush)
    }

    func flushPendingAutosavingNotes() async -> Bool {
        for workspace in tabs {
            guard await workspace.flushPendingAutosavingNotes() else { return false }
        }
        return true
    }

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
            return closeWorkspace(workspace, recordHistory: recordHistory)
        }
        guard let appDelegate = AppDelegate.shared,
              let windowId = appDelegate.windowId(for: self),
              appDelegate.mainWindow(for: windowId) != nil else { return false }
        if workspace.isRemoteTmuxMirror {
            appDelegate.remoteTmuxController.detachMirrorWorkspaceKeptOpenLocally(workspaceId: workspace.id)
        }
        return appDelegate.closeMainWindow(
            windowId: windowId,
            recordHistory: recordHistory
        ) { [weak workspace] in
            guard let workspace else { return }
            // Window unregister temporarily retains a recoverable route while
            // terminal surfaces remain registered. Final teardown follows the
            // asynchronous note flush and close snapshot.
            workspace.withClosedPanelHistorySuppressed {
                workspace.teardownAllPanels()
            }
            workspace.teardownRemoteConnection()
            workspace.owningTabManager = nil
        }
    }
}
