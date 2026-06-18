public import UserNotifications

/// A narrow seam over `UNUserNotificationCenter` used by
/// ``NotificationDeliveryCoordinator`` to install categories and its delegate.
@MainActor
public protocol UserNotificationCenterConfiguring: AnyObject {
    /// Installs the notification categories the app can deliver or respond to.
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)

    /// Installs the notification-center delegate that receives delivery and
    /// response callbacks.
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?)
}

extension UNUserNotificationCenter: UserNotificationCenterConfiguring {
    /// Installs `delegate` on the underlying `UNUserNotificationCenter`.
    public func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        self.delegate = delegate
    }
}
