public import Foundation

/// The window-side seam the notification-dismissal model drives: snapshot
/// reads of selection/panel/unread state and synchronous indicator
/// mutations on the notification store and the owning workspace.
///
/// **Why a synchronous two-way protocol and not an AsyncStream.** Every
/// legacy dismissal is one MainActor turn that interleaves reads (is the
/// workspace selected, does the panel still exist, which indicator classes
/// are lit) with writes (mark read, clear indicators, trigger the dismiss
/// flash). Pushing the writes through a stream would open a suspension
/// window in which user-driven mutations could interleave — an observable
/// change to indicator transitions. The model therefore stays `@MainActor`
/// and calls the host synchronously; the per-window `TabManager` is the
/// single implementer.
///
/// Reads return `false`/`nil` when the workspace or panel is gone,
/// mirroring the legacy optional-chained `tabs.first(where:)` lookups.
@MainActor
public protocol NotificationDismissalHosting: AnyObject {
    // MARK: Selection / environment reads

    /// The window's selected workspace id, if any.
    var selectedWorkspaceId: UUID? { get }
    /// Whether the app is active (legacy `AppFocusState.isAppActive()`).
    var isAppActive: Bool { get }
    /// Whether the notification store exists yet (legacy
    /// `AppDelegate.shared?.notificationStore` nil check).
    var hasNotificationStore: Bool { get }
    /// O(1) aggregate gate for any unread/visible state in a workspace.
    func storeHasDismissibleState(workspaceId: UUID) -> Bool
    /// O(1) aggregate for panel-local indicators that intentionally do not
    /// contribute to the notification store's workspace badge.
    func workspaceHasDismissiblePanelState(workspaceId: UUID) -> Bool
    /// The workspace's focused panel id, if any.
    func focusedPanelId(in workspaceId: UUID) -> UUID?
    /// The workspace's focused surface id, if any. Mirrors the delivery gate's
    /// `focusedSurfaceId(for:)` so the dismissal gate can compare a dismissal's
    /// target against the exact focused surface when
    /// ``suppressOnlyFocusedSurface`` is enabled.
    func focusedSurfaceId(in workspaceId: UUID) -> UUID?
    /// Resolves a surface-or-panel id to the workspace's panel id.
    func panelId(forSurfaceOrPanelId surfaceId: UUID, in workspaceId: UUID) -> UUID?

    // MARK: Policy reads

    /// Opt-in `notifications.suppressOnlyFocusedSurface`: when `true`, the
    /// implicit notification auto-withdraw fires only for the exact focused
    /// surface, leaving a non-focused surface's banner up until that surface is
    /// focused (or the notification is clicked/dismissed). When `false` (the
    /// default) the legacy workspace-visibility withdraw is preserved.
    var suppressOnlyFocusedSurface: Bool { get }

    // MARK: Workspace indicator reads

    /// Whether the panel carries a manually-set unread indicator.
    func workspaceHasManualPanelUnread(workspaceId: UUID, panelId: UUID) -> Bool
    /// Whether the panel carries a session-restored unread indicator.
    func workspaceHasRestoredPanelUnread(workspaceId: UUID, panelId: UUID) -> Bool

    // MARK: Notification store reads

    /// Whether the workspace carries a manually-set unread indicator.
    func storeHasManualUnread(workspaceId: UUID) -> Bool
    /// Whether the workspace carries a session-restored unread indicator.
    func storeHasRestoredUnreadIndicator(workspaceId: UUID) -> Bool
    /// Whether an unread notification exists for the workspace (or surface).
    func storeHasUnreadNotification(workspaceId: UUID, surfaceId: UUID?) -> Bool
    /// Whether policy evaluation is still pending for the workspace (or surface).
    func storeHasPendingNotification(workspaceId: UUID, surfaceId: UUID?) -> Bool
    /// Whether a visible notification indicator exists for the workspace
    /// (or surface).
    func storeHasVisibleNotificationIndicator(workspaceId: UUID, surfaceId: UUID?) -> Bool

    // MARK: Mutations

    /// Marks the workspace's (or surface's) notifications read.
    func storeMarkRead(workspaceId: UUID, surfaceId: UUID?)
    /// Clears the workspace-level manual unread indicator; returns whether
    /// anything was cleared.
    @discardableResult
    func storeClearManualUnread(workspaceId: UUID) -> Bool
    /// Clears the workspace-level restored unread indicator; returns whether
    /// anything was cleared.
    @discardableResult
    func storeClearRestoredUnreadIndicator(workspaceId: UUID) -> Bool
    /// Clears the focused-read indicator for the workspace (or surface).
    func storeClearFocusedReadIndicator(workspaceId: UUID, surfaceId: UUID?)
    /// Clears the panel's manually-set unread indicator.
    func workspaceClearManualUnread(workspaceId: UUID, panelId: UUID)
    /// Clears the panel's session-restored unread indicator.
    func workspaceClearRestoredUnreadIndicator(workspaceId: UUID, panelId: UUID)
    /// Flashes the panel to confirm a notification dismissal.
    func workspaceTriggerNotificationDismissFlash(workspaceId: UUID, panelId: UUID)
    /// Flashes the panel to confirm an unread-indicator dismissal.
    func workspaceTriggerUnreadIndicatorDismissFlash(workspaceId: UUID, panelId: UUID)
}
