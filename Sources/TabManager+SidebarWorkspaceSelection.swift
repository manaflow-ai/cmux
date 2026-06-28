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
        sidebarWorkspaceSelectionCoalescer.signal { [weak self] in
            guard let self,
                  let workspace = self.tabs.first(where: { $0.id == workspaceId })
            else { return }
            self.selectWorkspace(workspace)
        }
    }

    func cancelPendingSidebarWorkspaceSelection() {
        sidebarWorkspaceSelectionCoalescer.cancel()
    }
}
