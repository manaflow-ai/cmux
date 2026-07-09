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
/// All ids at this seam are STABLE MAC-SIDE NOTIFICATION IDS (the
/// `cmux.notificationId` payload key the Mac stamps on every forwarded
/// banner), never raw `UNNotificationRequest` identifiers: a delivered remote
/// notification's request identifier equals the `apns-collapse-id` only by
/// observed OS behavior, not by documented contract, so conformers map between
/// the two themselves (see
/// ``SystemDeliveredNotificationClearer/macNotificationID(for:)``).
public protocol DeliveredNotificationClearing: Sendable {
    /// Remove the delivered notifications carrying the given Mac notification
    /// ids, if present. Awaitable so a background push wake can finish the
    /// removal BEFORE reporting completion to iOS — returning early lets the
    /// system suspend the process with the work undone.
    /// - Parameter ids: The stable Mac-side notification ids to clear.
    func removeDelivered(ids: [String]) async

    /// The Mac notification ids of all currently delivered notifications, for
    /// the foreground reconcile sweep.
    func deliveredIdentifiers() async -> [String]

    /// SET the app-icon badge to the authoritative unread total computed by the
    /// Mac. Always an absolute value — never local +/-1 arithmetic — so any
    /// drift self-heals on the next event/push/reconcile.
    /// - Parameter count: The unread total; clamped to zero by conformers.
    func setBadgeCount(_ count: Int)
}
