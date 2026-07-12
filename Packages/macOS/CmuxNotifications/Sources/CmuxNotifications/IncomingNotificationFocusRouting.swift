/// Routes the AppKit-facing focus mutations requested for incoming notifications.
@MainActor
public protocol IncomingNotificationFocusRouting: AnyObject {
    /// Focuses the workspace and surface that produced a notification.
    ///
    /// - Parameter target: The workspace and optional surface to focus.
    /// - Returns: `true` when the target was focused.
    func focusIncomingNotification(_ target: IncomingNotificationFocusTarget) -> Bool

    /// Activates the app's preferred window when a notification target is unavailable.
    ///
    /// - Returns: `true` when a fallback window was activated.
    func activateApplicationForIncomingNotification() -> Bool
}
