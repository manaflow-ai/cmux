import CmuxBrowser
import Foundation

/// `TabManager`'s conformance to the `CmuxBrowser` ``ClosedBrowserPanelReopenHosting``
/// seam: the per-window workspace resolution, pre-reopen focused-panel read, and
/// the browser-availability gate the package ``ClosedBrowserPanelReopenCoordinator``
/// cannot own.
///
/// `TabManager` owns the tab list (`tabs`), the selected-workspace id, the
/// `PanelIdResolver`-backed `focusedPanelId(for:)` lookup, the
/// `selectWorkspaceId(_:notificationDismissalContext:)` selection flow (which
/// performs the app-side `AppDelegate.shared` notification-store dismissal), the
/// `FocusedSurfaceModel`-backed focus memory, and the `BrowserAvailabilitySettings`
/// gate — all app-target state. The coordinator drains the per-window
/// recently-closed stack and re-asserts focus; this conformance performs the exact
/// app-coupled effects the legacy
/// `reopenMostRecentlyClosedBrowserPanelFromLegacyStack` body inlined.
extension TabManager: ClosedBrowserPanelReopenHosting {
    // `isBrowserEnabled` (the `BrowserAvailabilitySettings.isEnabled()` gate) and
    // `selectedWorkspaceId` (== `selectedTabId`) are the same requirements the
    // `BrowserOpenHosting`/`NotificationDismissalHosting` conformances already
    // witness; a single witness satisfies every seam, so neither is redeclared
    // here. Likewise `rememberFocusedSurface(workspaceId:surfaceId:)` is witnessed
    // by the `FocusHistoryHosting` conformance, and
    // `selectWorkspaceForBrowserReopen(_:)` is the narrow internal entry point
    // co-located with the `private selectWorkspaceId(…)` in TabManager.swift.

    func reopenBrowserWorkspaceHandle(forWorkspaceId workspaceId: UUID) -> (any ClosedBrowserPanelReopenWorkspaceHandle)? {
        tabs.first(where: { $0.id == workspaceId })
    }

    func focusedPanelId(forWorkspaceId workspaceId: UUID) -> UUID? {
        focusedPanelId(for: workspaceId)
    }
}
