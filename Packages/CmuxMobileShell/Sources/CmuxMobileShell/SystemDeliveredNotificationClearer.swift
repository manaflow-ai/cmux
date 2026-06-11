public import Foundation
internal import UserNotifications

/// Production ``DeliveredNotificationClearing`` backed by the system
/// `UNUserNotificationCenter`.
///
/// The seam speaks STABLE MAC-SIDE NOTIFICATION IDS, not raw
/// `UNNotificationRequest` identifiers: a delivered remote notification's
/// request identifier is only the `apns-collapse-id` by observed OS behavior,
/// not a documented contract, so every operation maps through the
/// authoritative `cmux.notificationId` payload key (with the request
/// identifier as fallback for pushes that predate the key). Clearing and the
/// delivered-id read are awaited (a background push wake must finish removal
/// before reporting completion to iOS); the badge write is best-effort
/// fire-and-forget. This is the default the app composition root supplies to
/// ``MobileShellComposite``.
public struct SystemDeliveredNotificationClearer: DeliveredNotificationClearing {
    /// Creates a clearer over the shared notification center.
    public init() {}

    public func removeDelivered(ids: [String]) async {
        guard !ids.isEmpty else { return }
        let targets = Set(ids)
        // Resolve the Mac ids to the actual delivered request identifiers
        // first, because removeDeliveredNotifications matches only on request
        // identifiers. Awaited (not fire-and-forget) so a background push wake
        // cannot report completion to iOS before the removal ran.
        let center = UNUserNotificationCenter.current()
        let matching = await center.deliveredNotifications()
            .filter { targets.contains(Self.macNotificationID(for: $0.request)) }
            .map(\.request.identifier)
        guard !matching.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: matching)
    }

    public func deliveredIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current()
            .deliveredNotifications()
            .map { Self.macNotificationID(for: $0.request) }
    }

    public func setBadgeCount(_ count: Int) {
        // Fire-and-forget: a badge write failure (no authorization yet) is
        // non-fatal and the next event/push/reconcile sets the total again.
        UNUserNotificationCenter.current().setBadgeCount(max(0, count), withCompletionHandler: nil)
    }

    /// The stable Mac-side notification id for a delivered banner: the
    /// `cmux.notificationId` payload key when present (authoritative — the Mac
    /// stamps it on every forwarded banner), else the request identifier. The
    /// fallback keeps older deliveries reconcilable when their request
    /// identifier happens to be the collapse-id, and is harmless otherwise: an
    /// OS-assigned random identifier matches no Mac notification, so the Mac
    /// never classifies it as handled and the banner is left alone.
    static func macNotificationID(for request: UNNotificationRequest) -> String {
        if let cmux = request.content.userInfo["cmux"] as? [String: Any],
           let id = (cmux["notificationId"] as? String)?.trimmingCharacters(in: .whitespaces),
           !id.isEmpty {
            return id
        }
        return request.identifier
    }
}
