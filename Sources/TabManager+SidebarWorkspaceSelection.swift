import Foundation

extension TabManager {
    /// Debounces a normal sidebar workspace-row click so a rapid burst collapses
    /// into one switch to the last-clicked workspace. A click on the already-selected
    /// workspace instead cancels pending work and dismisses its notification directly.
    func requestSidebarWorkspaceSelection(_ workspace: Workspace) {
        if selectedTabId == workspace.id {
            cancelPendingSidebarWorkspaceSelection()
            dismissNotificationOnDirectInteraction(
                tabId: workspace.id,
                surfaceId: focusedSurfaceId(for: workspace.id)
            )
            return
        }

        let workspaceId = workspace.id
        sidebarWorkspaceSelectionCoalescer.debounce { [weak self] in
            self?.selectWorkspace(byId: workspaceId)
        }
    }

    func cancelPendingSidebarWorkspaceSelection() {
        sidebarWorkspaceSelectionCoalescer.cancel()
    }
}
