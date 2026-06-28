import Foundation

extension TabManager {
    /// Selects the workspace for a normal sidebar workspace-row click. A click on
    /// the already-selected workspace dismisses its notification directly instead.
    func requestSidebarWorkspaceSelection(_ workspace: Workspace) {
        if selectedTabId == workspace.id {
            dismissNotificationOnDirectInteraction(
                tabId: workspace.id,
                surfaceId: focusedSurfaceId(for: workspace.id)
            )
            return
        }

        selectWorkspace(workspace)
    }
}
