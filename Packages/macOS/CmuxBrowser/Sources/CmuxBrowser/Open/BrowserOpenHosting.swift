public import Foundation

/// The window-side seam ``BrowserOpenCoordinator`` drives for the workspace
/// resolution, selection, and focus-memory effects it cannot own from the
/// package.
///
/// `TabManager` owns the per-window tab list (`tabs`), the selected-workspace id
/// and the `selectWorkspaceId(_:notificationDismissalContext:)` selection flow
/// (which performs the app-side `AppDelegate.shared` notification-store
/// dismissal), and the `FocusedSurfaceModel`-backed focus memory
/// (`rememberFocusedSurface(tabId:surfaceId:)`). None of those can move down, so
/// `TabManager` conforms to this seam and the coordinator forwards through it.
///
/// The browser-availability gate (`BrowserAvailabilitySettings.isEnabled()`)
/// also stays app-side and is read through ``isBrowserEnabled``, matching every
/// legacy body's leading `guard BrowserAvailabilitySettings.isEnabled()`.
///
/// `@MainActor` because every effect is one main-actor turn driven by a keyboard
/// shortcut, command palette, menu, or the command socket, and both the host and
/// the resolved workspace handle live there — co-locating removes any bridging,
/// the same isolation ruling as the sibling focused-browser/terminal
/// coordinators.
@MainActor
public protocol BrowserOpenHosting: AnyObject {
    /// Whether browser surfaces may be created right now
    /// (`BrowserAvailabilitySettings.isEnabled()`). Every open/split/surface
    /// path returns early when this is `false`.
    var isBrowserEnabled: Bool { get }

    /// The currently selected workspace id, if any (legacy `selectedTabId`).
    var selectedWorkspaceId: UUID? { get }

    /// Resolves a workspace id to its browser-open handle, or `nil` when no live
    /// workspace matches (legacy `tabs.first(where: { $0.id == tabId })`).
    func browserOpenWorkspaceHandle(forWorkspaceId workspaceId: UUID) -> (any BrowserOpenWorkspaceHandle)?

    /// The remembered focused panel id for `workspaceId`, if any. Lives on the
    /// host because the focus memory is the per-window `FocusedSurfaceModel`
    /// (legacy `focusedSurface.rememberedFocusedPanelId(tabId)`), not workspace
    /// state.
    func rememberedFocusedPanelId(forWorkspaceId workspaceId: UUID) -> UUID?

    /// Selects `workspaceId` through the legacy
    /// `selectWorkspaceId(_:notificationDismissalContext: .explicitWorkspaceResume)`
    /// flow, which performs the app-side notification-store dismissal. Called
    /// only when the workspace is not already selected, matching the legacy
    /// `if selectedTabId != tabId { selectWorkspaceId(…) }` guard.
    func selectWorkspaceForBrowserOpen(_ workspaceId: UUID)

    /// Records `surfaceId` as the remembered focused surface for `workspaceId`
    /// (legacy `rememberFocusedSurface(tabId:surfaceId:)`).
    func rememberFocusedSurface(workspaceId: UUID, surfaceId: UUID)
}
