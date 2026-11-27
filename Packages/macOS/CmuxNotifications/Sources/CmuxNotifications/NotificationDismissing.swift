public import Foundation

/// The per-window notification-dismissal seam the app target consumes:
/// focus/interaction-driven dismissals plus the two pieces of dismissal
/// bookkeeping that ride along with workspace selection (the pending
/// selection context and the focus-flash suppression latch).
@MainActor
public protocol NotificationDismissing: AnyObject {
    /// Wires the window-side host. Call before the first selection so the
    /// initial workspace's dismissal bookkeeping reaches the host.
    func attach(host: any NotificationDismissalHosting)

    /// Whether focus-driven dismissals are currently suppressed
    /// (jump-to-unread sets this around its focus mutation so the flash is
    /// not double-triggered).
    var suppressesFocusFlash: Bool { get }
    /// Sets the focus-flash suppression latch.
    func setSuppressesFocusFlash(_ suppresses: Bool)

    /// Stores the dismissal context to apply once the in-flight workspace
    /// selection lands (the legacy `pendingSelectedTabNotificationDismissContext`).
    func setPendingSelectionContext(_ context: NotificationDismissalContext?)
    /// Returns and clears the pending selection context.
    func takePendingSelectionContext() -> NotificationDismissalContext?

    /// Dismisses the focused panel's notification when the workspace is
    /// selected and the app is active; consumes the focus-flash latch.
    func dismissFocusedPanelNotificationIfActive(workspaceId: UUID, context: NotificationDismissalContext)
    /// Focus-observer entry point: maps `explicitFocusIntent` onto
    /// direct-interaction vs active-focus context.
    func dismissPanelNotificationOnFocus(workspaceId: UUID, panelId: UUID, explicitFocusIntent: Bool)
    /// Dismisses for a direct user interaction with the panel.
    @discardableResult
    func dismissNotificationOnDirectInteraction(workspaceId: UUID, surfaceId: UUID?) -> Bool
    /// General dismissal entry point with an explicit context (the legacy
    /// private `dismissNotification(tabId:surfaceId:context:)` core, used by
    /// the focus-tab resume path).
    @discardableResult
    func dismissNotification(workspaceId: UUID, surfaceId: UUID?, context: NotificationDismissalContext) -> Bool
    /// Dismisses for typing into the terminal.
    @discardableResult
    func dismissNotificationOnTerminalInteraction(workspaceId: UUID, surfaceId: UUID?) -> Bool
}
