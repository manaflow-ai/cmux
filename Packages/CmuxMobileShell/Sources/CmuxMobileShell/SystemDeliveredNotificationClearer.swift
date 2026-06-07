public import Foundation
internal import UserNotifications

/// Production ``DeliveredNotificationClearing`` backed by the system
/// `UNUserNotificationCenter`.
///
/// `removeDeliveredNotifications(withIdentifiers:)` is available on both iOS and
/// macOS; clearing is a best-effort fire-and-forget that never blocks the
/// caller. This is the default the app composition root supplies to
/// ``MobileShellComposite``.
public struct SystemDeliveredNotificationClearer: DeliveredNotificationClearing {
    /// Creates a clearer over the shared notification center.
    public init() {}

    public func removeDelivered(ids: [String]) {
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
}
