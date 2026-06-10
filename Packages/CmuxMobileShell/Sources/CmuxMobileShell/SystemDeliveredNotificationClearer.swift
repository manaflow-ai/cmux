public import Foundation
internal import UserNotifications

/// Production ``DeliveredNotificationClearing`` backed by the system
/// `UNUserNotificationCenter`.
///
/// All three operations are available on both iOS and macOS. Clearing and badge
/// writes are best-effort fire-and-forget that never block the caller; the
/// delivered-identifier read is the only awaited call (it feeds the reconcile
/// sweep). This is the default the app composition root supplies to
/// ``MobileShellComposite``.
public struct SystemDeliveredNotificationClearer: DeliveredNotificationClearing {
    /// Creates a clearer over the shared notification center.
    public init() {}

    public func removeDelivered(ids: [String]) {
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    public func deliveredIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current()
            .deliveredNotifications()
            .map(\.request.identifier)
    }

    public func setBadgeCount(_ count: Int) {
        // Fire-and-forget: a badge write failure (no authorization yet) is
        // non-fatal and the next event/push/reconcile sets the total again.
        UNUserNotificationCenter.current().setBadgeCount(max(0, count), withCompletionHandler: nil)
    }
}
