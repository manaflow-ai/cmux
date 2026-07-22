public import UserNotifications

/// A narrow seam over `UNUserNotificationCenter` used by
/// ``NotificationDeliveryCoordinator`` to install categories and its delegate.
@MainActor
public protocol UserNotificationCenterConfiguring: AnyObject {
    /// Reads the currently registered notification categories.
    func currentNotificationCategories() async -> Set<UNNotificationCategory>

    /// Installs the notification categories the app can deliver or respond to.
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)

    /// Installs the notification-center delegate that receives delivery and
    /// response callbacks.
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?)
}

extension UNUserNotificationCenter: UserNotificationCenterConfiguring {
    /// Reads the categories currently registered on the notification center.
    public func currentNotificationCategories() async -> Set<UNNotificationCategory> {
        await notificationCategories()
    }

    /// Installs `delegate` on the underlying `UNUserNotificationCenter`.
    public func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        self.delegate = delegate
    }
}
