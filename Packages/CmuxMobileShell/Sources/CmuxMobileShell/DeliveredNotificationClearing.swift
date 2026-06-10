public import Foundation

/// The system-notification surface for cross-device dismiss-sync: clearing
/// already-delivered banners, enumerating them for the reconcile sweep, and
/// setting the app-icon badge.
///
/// A seam over `UNUserNotificationCenter` so ``MobileShellComposite`` can react
/// to Mac-side `notification.dismissed` / `notification.badge` events and run
/// the foreground reconcile without hardcoding the
/// `UNUserNotificationCenter.current()` singleton. The production conformance is
/// ``SystemDeliveredNotificationClearer``; tests inject a fake to assert which
/// ids were cleared and which badge counts were applied.
///
/// The identifiers are the delivered remote notifications' `request.identifier`,
/// which (because the Mac stamps each push with `apns-collapse-id = notificationId`)
/// equal the stable Mac-side notification ids carried in the dismiss event.
public protocol DeliveredNotificationClearing: Sendable {
    /// Remove the delivered notifications with the given identifiers, if present.
    /// - Parameter ids: The delivered-notification identifiers to clear.
    func removeDelivered(ids: [String])

    /// The identifiers of all currently delivered notifications, for the
    /// foreground reconcile sweep.
    func deliveredIdentifiers() async -> [String]

    /// SET the app-icon badge to the authoritative unread total computed by the
    /// Mac. Always an absolute value — never local +/-1 arithmetic — so any
    /// drift self-heals on the next event/push/reconcile.
    /// - Parameter count: The unread total; clamped to zero by conformers.
    func setBadgeCount(_ count: Int)
}
