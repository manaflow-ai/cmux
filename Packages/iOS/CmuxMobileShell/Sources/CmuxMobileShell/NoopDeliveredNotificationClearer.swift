/// No-op ``DeliveredNotificationClearing`` for preview stores.
///
/// A preview/test store must never mutate the real system notification
/// center or app badge, and `UNUserNotificationCenter.current()` traps in
/// processes without a bundle proxy (e.g. `swift test`), so
/// ``MobileShellComposite/preview(runtime:)`` injects this instead of
/// ``SystemDeliveredNotificationClearer``.
struct NoopDeliveredNotificationClearer: DeliveredNotificationClearing {
    func removeDelivered(ids: [String]) async {}
    func deliveredIdentifiers() async -> [String] { [] }
    func setBadgeCount(_ count: Int) {}
}
