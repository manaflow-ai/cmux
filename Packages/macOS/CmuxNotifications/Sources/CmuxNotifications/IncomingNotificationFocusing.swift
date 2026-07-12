/// Applies the shared opt-in focus policy for incoming notifications.
@MainActor
public protocol IncomingNotificationFocusing: AnyObject {
    /// Focuses an incoming notification when desktop delivery and user policy allow it.
    ///
    /// - Parameters:
    ///   - target: The notification's workspace and optional surface, or `nil` when unavailable.
    ///   - isDesktopDeliveryEnabled: Whether notification policy requested desktop delivery.
    /// - Returns: The focus action that was taken.
    func focusIfNeeded(
        target: IncomingNotificationFocusTarget?,
        isDesktopDeliveryEnabled: Bool
    ) -> IncomingNotificationFocusOutcome
}
