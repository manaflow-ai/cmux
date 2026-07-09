import CmuxPanes
import Foundation

/// `TabManager`'s conformance to the `CmuxPanes` ``SurfaceSplitHosting`` seam:
/// the per-window workspace resolution and the app-coupled Sentry-breadcrumb /
/// notification-store effects the package ``SurfaceSplitCoordinator`` cannot own.
///
/// `TabManager` owns the tab list, the selected-workspace id, the app-target
/// Sentry breadcrumb trail, and the environment notification-store reach path —
/// all app-target state. The coordinator keeps the resolution/guard/creation
/// orchestration; this conformance performs the exact app-coupled effects the
/// legacy `createSplit`/`closeSurface` bodies inlined.
extension TabManager: SurfaceSplitHosting {
    // `selectedWorkspaceId` (== `selectedTabId`) is the same requirement the
    // `NotificationDismissalHosting`/`BrowserOpenHosting` conformances already
    // witness (TabManager+NotificationDismissalHosting.swift); a single witness
    // satisfies all three seams, so it is not redeclared here.

    func surfaceSplitWorkspaceHandle(forWorkspaceId workspaceId: UUID) -> (any SurfaceSplitWorkspaceHandle)? {
        tabs.first(where: { $0.id == workspaceId })
    }

    var selectedSurfaceSplitWorkspaceHandle: (any SurfaceSplitWorkspaceHandle)? {
        selectedWorkspace
    }

    func recordSplitCreateBreadcrumb(direction: String) {
        sentryBreadcrumb("split.create", data: ["direction": direction])
    }

    func clearNotifications(forWorkspaceId workspaceId: UUID, surfaceId: UUID) {
        appEnvironment?.notificationStore?.clearNotifications(forTabId: workspaceId, surfaceId: surfaceId)
    }
}
