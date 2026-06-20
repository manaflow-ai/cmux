public import Foundation

/// The window-side seam ``SurfaceSplitCoordinator`` drives for the workspace
/// resolution and the app-coupled side effects it cannot own from the package.
///
/// `TabManager` owns the per-window tab list (`tabs`), the selected-workspace id
/// (`selectedTabId`), the app-target Sentry breadcrumb trail, and the
/// `AppDelegate.shared` notification-store (whose per-surface clear runs after a
/// close). None of those can move down, so `TabManager` conforms to this seam and
/// the coordinator forwards through it.
///
/// `@MainActor` because every effect is one main-actor turn driven by a keyboard
/// shortcut, command palette, menu, or the command socket, and both the host and
/// the resolved workspace handle live there — co-locating removes any bridging,
/// the same isolation ruling as the sibling ``BrowserOpenHosting`` /
/// ``SplitMoveReorderHosting`` seams.
@MainActor
public protocol SurfaceSplitHosting: AnyObject {
    /// The currently selected workspace id, if any (legacy `selectedTabId`).
    var selectedWorkspaceId: UUID? { get }

    /// Resolves a workspace id to its surface-split handle, or `nil` when no live
    /// workspace matches (legacy `tabs.first(where: { $0.id == tabId })`).
    func surfaceSplitWorkspaceHandle(forWorkspaceId workspaceId: UUID) -> (any SurfaceSplitWorkspaceHandle)?

    /// The handle for the currently selected workspace, if any (legacy
    /// `selectedWorkspace`). A distinct member because the legacy
    /// surface-navigation/`newSurface` bodies resolve `selectedWorkspace`
    /// directly rather than going through `selectedTabId` + the tab lookup.
    var selectedSurfaceSplitWorkspaceHandle: (any SurfaceSplitWorkspaceHandle)? { get }

    /// Records a Sentry breadcrumb (legacy `sentryBreadcrumb(_:data:)`). Stays
    /// app-side because the Sentry SDK is app-target only. The data dictionary is
    /// kept `[String: String]` so the package never speaks the legacy `[String:
    /// Any]` payload type; `SurfaceSplitCoordinator` only ever passed string
    /// values, matching the single legacy `["direction": String(describing:)]`
    /// call.
    func recordSplitCreateBreadcrumb(direction: String)

    /// Clears notifications for the closed surface (legacy
    /// `AppDelegate.shared?.notificationStore?.clearNotifications(forTabId:
    /// surfaceId:)`). Stays app-side because the notification store is owned by
    /// the app target.
    func clearNotifications(forWorkspaceId workspaceId: UUID, surfaceId: UUID)
}
