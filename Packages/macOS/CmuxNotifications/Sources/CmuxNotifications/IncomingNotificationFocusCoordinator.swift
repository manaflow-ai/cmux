public import Observation

/// Coordinates opt-in app activation and target navigation for incoming notifications.
@MainActor
@Observable
public final class IncomingNotificationFocusCoordinator: IncomingNotificationFocusing {
    private let routing: any IncomingNotificationFocusRouting
    private let isEnabled: @MainActor () -> Bool
    private let isApplicationActive: @MainActor () -> Bool

    /// Creates an incoming-notification focus coordinator with injected policy and routing seams.
    ///
    /// - Parameters:
    ///   - routing: The app-side focus and activation router.
    ///   - isEnabled: Returns whether the user enabled automatic notification focus.
    ///   - isApplicationActive: Returns whether cmux is already the active application.
    public init(
        routing: any IncomingNotificationFocusRouting,
        isEnabled: @escaping @MainActor () -> Bool,
        isApplicationActive: @escaping @MainActor () -> Bool
    ) {
        self.routing = routing
        self.isEnabled = isEnabled
        self.isApplicationActive = isApplicationActive
    }

    /// Applies focus only for desktop-eligible notifications while cmux is inactive.
    ///
    /// A resolved target is preferred. If it cannot be focused, the coordinator
    /// activates the app's preferred window so the original notification delivery
    /// can remain visible and unread.
    ///
    /// - Parameters:
    ///   - target: The notification's workspace and optional surface, or `nil` when unavailable.
    ///   - isDesktopDeliveryEnabled: Whether notification policy requested desktop delivery.
    /// - Returns: The focus action that was taken.
    public func focusIfNeeded(
        target: IncomingNotificationFocusTarget?,
        isDesktopDeliveryEnabled: Bool
    ) -> IncomingNotificationFocusOutcome {
        guard isDesktopDeliveryEnabled, isEnabled(), !isApplicationActive() else {
            return .ignored
        }
        if let target, routing.focusIncomingNotification(target) {
            return .focusedTarget
        }
        if routing.activateApplicationForIncomingNotification() {
            return .activatedFallback
        }
        return .unavailable
    }
}
