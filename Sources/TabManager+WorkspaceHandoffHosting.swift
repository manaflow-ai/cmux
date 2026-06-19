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
        // Resolve from `tabsPublisher.value` rather than `tabs`: `tabsPublisher`
        // is sent during the tabs `willSet`, so when the reconcile runs from the
        // tabs-publisher `.onReceive` path the new workspace list is already the
        // publisher's value while `tabs` storage still holds the old list. The
        // legacy `reconcileMountedWorkspaceIds(tabs:)` iterated that same new
        // list (the closure's `tabs` param) when toggling portals, so a
        // just-added workspace's portal is set, not skipped. Outside the willSet
        // window `tabsPublisher.value == tabs`, so every other path is identical.
        guard let workspace = tabsPublisher.value.first(where: { $0.id == workspaceId }) else { return }
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
