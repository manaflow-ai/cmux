import CmuxBrowser
import Foundation

/// `TabManager`'s conformance to the `CmuxBrowser` ``BrowserOpenHosting`` seam:
/// the per-window workspace resolution, selection, focus-memory, and
/// browser-availability effects the package ``BrowserOpenCoordinator`` cannot
/// own.
///
/// `TabManager` owns the tab list, the selected-workspace id, the
/// `selectWorkspaceId(_:notificationDismissalContext:)` selection flow (which
/// performs the app-side `AppDelegate.shared` notification-store dismissal), the
/// `FocusedSurfaceModel`-backed focus memory, and the
/// `BrowserAvailabilitySettings` gate — all app-target state. The coordinator
/// keeps the split-right reuse/split-source policy and the default
/// focused-or-first-pane open path; this conformance performs the exact
/// app-coupled effects the legacy `openBrowser` bodies inlined.
extension TabManager: BrowserOpenHosting {
    var isBrowserEnabled: Bool {
        BrowserAvailabilitySettings.isEnabled()
    }

    // `selectedWorkspaceId` (== `selectedTabId`) is the same requirement the
    // `NotificationDismissalHosting` conformance already witnesses
    // (TabManager+NotificationDismissalHosting.swift); a single witness
    // satisfies both seams, so it is not redeclared here.

    func browserOpenWorkspaceHandle(forWorkspaceId workspaceId: UUID) -> (any BrowserOpenWorkspaceHandle)? {
        tabs.first(where: { $0.id == workspaceId })
    }

    func rememberedFocusedPanelId(forWorkspaceId workspaceId: UUID) -> UUID? {
        focusedSurface.rememberedFocusedPanelId(workspaceId)
    }

    // `selectWorkspaceForBrowserOpen(_:)` is a narrow internal entry point
    // co-located with the `private selectWorkspaceId(_:notificationDismissalContext:)`
    // it wraps (TabManager.swift), so the private selection flow — and its
    // app-side notification-store dismissal — stays private rather than widening
    // to internal. `rememberFocusedSurface(workspaceId:surfaceId:)` is the same
    // requirement the `FocusHistoryHosting` conformance already witnesses
    // (TabManager+FocusHistoryHosting.swift); a single witness satisfies both
    // seams, so neither is redeclared here.
}
