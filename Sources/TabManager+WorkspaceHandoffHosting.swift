import CmuxWorkspaces
import Foundation

/// The window-side host for the CmuxWorkspaces ``WorkspaceHandoffCoordinator``:
/// the ordered-workspace/selection/pinning/cycle-hot snapshot reads plus the
/// portal-rendering toggle and immediate-handoff readiness check the
/// mount-reconcile and handoff state machine performs. Mirrors the legacy
/// `ContentView` reach into `tabManager`/`Workspace` so a gone workspace makes
/// the portal mutation a no-op and the readiness check returns `true`.
///
/// `orderedWorkspaceIds()`, `selectedWorkspaceId`, and
/// `completePendingWorkspaceUnfocus(reason:)` are already witnessed by the
/// SidebarGitHosting / FocusedSurfaceHosting / FocusHistoryHosting
/// conformances, and `mountedBackgroundWorkspaceLoadIds`,
/// `debugPinnedWorkspaceLoadIds`, and `isWorkspaceCycleHot` are satisfied
/// directly by `TabManager`'s like-named stored properties; one declaration
/// satisfies all seams. `logWorkspaceHandoffEvent(_:)` lives in
/// `TabManager.swift` because it reads the `private` DEBUG workspace-switch
/// snapshot and formatter helpers.
extension TabManager: WorkspaceHandoffHosting {
    func setWorkspacePortalRenderingEnabled(workspaceId: UUID, enabled: Bool, reason: String) {
        // Resolve from `tabs` directly. The reconcile that drives this now runs
        // from the `@Observable` `workspaces.tabs` observation, which fires after
        // the `tabs` mutation commits, so `tabs` already holds the new workspace
        // list — the value the retired `tabsPublisher` carried during the willSet
        // window. (The former code read `tabsPublisher.value` precisely because
        // the bridge emitted the new list during `willSet` while `tabs` storage
        // still held the old one; post-change observation removes that skew.)
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return }
        workspace.setPortalRenderingEnabled(enabled, reason: reason)
    }

    func workspaceIsReadyForImmediateHandoff(workspaceId: UUID) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return true }
        if let focusedPanelId = workspace.focusedPanelId,
           workspace.browserPanel(for: focusedPanelId) != nil {
            return true
        }
        return workspace.hasLoadedTerminalSurface()
    }
}
