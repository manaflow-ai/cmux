import Bonsplit
import CmuxWorkspaces
import Foundation

/// The window-side host for the CmuxWorkspaceNavigation focus-history
/// model: snapshot reads of workspace/panel existence, titles, and
/// remembered focus, plus the synchronous selection/focus mutations a
/// history navigation performs. Lookups mirror the legacy optional-chained
/// `tabs.first(where:)` reads, so a gone workspace/panel makes every read
/// `false`/`nil` and every mutation a no-op.
///
/// `selectedWorkspaceId`, `workspaceExists(_:)`, and
/// `panelExists(workspaceId:panelId:)` are already witnessed by the
/// NotificationDismissalHosting/SidebarGitHosting conformances; one
/// declaration satisfies all seams. `focusSelectedWorkspacePanel()` and
/// `focusHistoryRevisionDidChange()` live in `TabManager.swift` because
/// they touch `private` members (`focusSelectedTabPanel`,
/// `focusHistoryRevision`).
extension TabManager: FocusHistoryHosting {
    func workspaceTitle(_ workspaceId: UUID) -> String? {
        tabs.first(where: { $0.id == workspaceId })?.title
    }

    func panelTitle(workspaceId: UUID, panelId: UUID) -> String? {
        tabs.first(where: { $0.id == workspaceId })?.panelTitle(panelId: panelId)
    }

    func rememberedFocusedPanelId(_ workspaceId: UUID) -> UUID? {
        focusedPanelId(for: workspaceId)
    }

    func workspaceFocusedPanelId(_ workspaceId: UUID) -> UUID? {
        tabs.first(where: { $0.id == workspaceId })?.focusedPanelId
    }

    func firstPanelIdSortedByUUIDString(_ workspaceId: UUID) -> UUID? {
        tabs.first(where: { $0.id == workspaceId })?
            .panels.keys.sorted { $0.uuidString < $1.uuidString }.first
    }

    func selectWorkspace(_ workspaceId: UUID) {
        if selectedTabId != workspaceId {
            selectedTabId = workspaceId
        }
    }

    func rememberFocusedSurface(workspaceId: UUID, surfaceId: UUID) {
        rememberFocusedSurface(tabId: workspaceId, surfaceId: surfaceId)
    }

    func focusPanel(workspaceId: UUID, panelId: UUID) {
        tabs.first(where: { $0.id == workspaceId })?.focusPanel(panelId)
    }

    func triggerFocusFlash(workspaceId: UUID, panelId: UUID) {
        tabs.first(where: { $0.id == workspaceId })?.triggerFocusFlash(panelId: panelId)
    }

    /// Resolves the panel id the focus-history recording path should store for
    /// a focused surface, falling back to the surface id when the workspace or
    /// its surface->panel mapping is gone (legacy
    /// `tabs.first(...)?.panelIdFromSurfaceId(...) ?? surfaceId`). Lifted from
    /// `TabManager.swift`; not part of the `FocusHistoryHosting` seam because
    /// only the focus-surface observer (same window) consumes it.
    func panelIdForFocusHistorySurface(_ surfaceId: UUID, workspaceId: UUID) -> UUID {
        tabs.first(where: { $0.id == workspaceId })?.panelIdFromSurfaceId(TabID(uuid: surfaceId)) ?? surfaceId
    }
}
