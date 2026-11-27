public import UserNotifications

/// A narrow seam used by ``NotificationDeliveryCoordinator`` to install categories and its delegate.
@MainActor
public protocol UserNotificationCenterConfiguring: Sendable {
    /// Installs notification categories without blocking the main actor.
    /// - Parameter categories: Every category the application can deliver.
    /// - Returns: Success, a framework error, or a bounded timeout.
    func setNotificationCategories(
        _ categories: Set<UNNotificationCategory>
    ) async -> Result<Void, UserNotificationCenterFailure>

    /// Reads the currently registered notification categories, so installers
    /// and owners of dynamic per-request categories can merge instead of
    /// clobbering each other's registrations.
    func notificationCategories() async -> Result<
        Set<UNNotificationCategory>,
        UserNotificationCenterFailure
    >

    /// Installs the notification-center delegate that receives delivery and
    /// response callbacks.
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?)
}
