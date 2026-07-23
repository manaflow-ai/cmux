import Foundation

extension TabManager {
    /// Closes an explicitly targeted panel without an interactive veto while
    /// preserving the Close Tab preference for a workspace's final panel.
    @discardableResult
    func closePanelNonInteractively(
        workspaceID: UUID,
        panelID: UUID,
        allowPinnedWorkspace: Bool = false
    ) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == workspaceID }),
              workspace.panels[panelID] != nil,
              let surfaceID = workspace.surfaceIdFromPanelId(panelID) else {
            return false
        }
        if closeWorkspaceOnLastSurfacePreferenceEnabled(),
           workspace.panels.count == 1 {
            return closeWorkspaceNonInteractively(
                workspace,
                allowPinned: allowPinnedWorkspace
            )
        }
        workspace.markExplicitClose(surfaceId: surfaceID)
        return workspace.requestNonInteractiveCloseTabRecordingHistory(surfaceID)
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

    /// Closes the exact workspace set without presenting per-workspace or
    /// group-anchor confirmation. Every requested ID must still be live.
    @discardableResult
    func closeWorkspacesNonInteractively(
        _ workspaceIDs: [UUID],
        allowPinned: Bool = false
    ) -> Bool {
        let requestedIDs = Set(workspaceIDs)
        guard !requestedIDs.isEmpty else { return false }
        let orderedWorkspaces = tabs.filter { requestedIDs.contains($0.id) }
        guard orderedWorkspaces.count == requestedIDs.count,
              allowPinned || orderedWorkspaces.allSatisfy({ !$0.isPinned }) else {
            return false
        }
        for workspace in orderedWorkspaces {
            guard closeWorkspaceNonInteractively(
                workspace,
                allowPinned: allowPinned
            ) else {
                return false
            }
        }
        return true
    }
}
