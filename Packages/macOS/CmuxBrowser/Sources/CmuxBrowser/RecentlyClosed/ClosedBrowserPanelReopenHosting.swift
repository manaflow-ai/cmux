public import Foundation

/// The window-side seam ``ClosedBrowserPanelReopenCoordinator`` drives for the
/// workspace resolution, selection, focus-memory, and browser-availability
/// effects it cannot own from the package.
///
/// `TabManager` owns the per-window tab list (`tabs`), the selected-workspace id,
/// the `selectWorkspaceId(_:notificationDismissalContext:)` selection flow (which
/// performs the app-side `AppDelegate.shared` notification-store dismissal), the
/// `PanelIdResolver`-backed `focusedPanelId(for:)` lookup, and the
/// `FocusedSurfaceModel`-backed focus memory (`rememberFocusedSurface`). None of
/// those can move down, so `TabManager` conforms to this seam and the coordinator
/// forwards through it.
///
/// The browser-availability gate (`BrowserAvailabilitySettings.isEnabled()`)
/// also stays app-side and is read through ``isBrowserEnabled``, matching the
/// legacy `reopenMostRecentlyClosedBrowserPanelFromLegacyStack` body's leading
/// `guard BrowserAvailabilitySettings.isEnabled()`.
///
/// `@MainActor` because every effect is one main-actor turn driven by the
/// Cmd+Shift+T reopen shortcut (and its menu/command-palette equivalents), and
/// both the host and the resolved workspace handle live there — co-locating
/// removes any bridging, the same isolation ruling as the sibling
/// ``BrowserOpenCoordinator``.
@MainActor
public protocol ClosedBrowserPanelReopenHosting: AnyObject {
    /// Whether browser surfaces may be created right now
    /// (`BrowserAvailabilitySettings.isEnabled()`). The reopen walk returns early
    /// when this is `false`.
    var isBrowserEnabled: Bool { get }

    /// The currently selected workspace id, if any (legacy `selectedTabId`).
    var selectedWorkspaceId: UUID? { get }

    /// Resolves a workspace id to its reopen handle, or `nil` when no live
    /// workspace matches (legacy `tabs.first(where: { $0.id == workspaceId })`).
    /// A `nil` result drops the stale snapshot rather than barging into the
    /// currently-selected workspace.
    func reopenBrowserWorkspaceHandle(forWorkspaceId workspaceId: UUID) -> (any ClosedBrowserPanelReopenWorkspaceHandle)?

    /// The workspace's currently focused panel id captured before the reopen
    /// (legacy `focusedPanelId(for: targetWorkspace.id)`), used so the post-reopen
    /// focus enforcement only re-asserts focus when it drifted back to that panel.
    func focusedPanelId(forWorkspaceId workspaceId: UUID) -> UUID?

    /// Selects `workspaceId` through the legacy
    /// `selectWorkspaceId(_:notificationDismissalContext: .explicitWorkspaceResume)`
    /// flow, which performs the app-side notification-store dismissal. Called
    /// only when the workspace is not already selected, matching the legacy
    /// `if selectedTabId != targetWorkspace.id { selectWorkspaceId(…) }` guard.
    func selectWorkspaceForBrowserReopen(_ workspaceId: UUID)

    /// Records `surfaceId` as the remembered focused surface for `workspaceId`
    /// (legacy `rememberFocusedSurface(tabId:surfaceId:)`).
    func rememberFocusedSurface(workspaceId: UUID, surfaceId: UUID)
}
