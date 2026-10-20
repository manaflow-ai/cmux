/// The outcome of dismissing a single notification by id (`notification.dismiss`
/// with an `id` selector).
///
/// The legacy body captured the notification's payload before removing it, or
/// reported not-found when no notification matched.
public enum ControlNotificationDismissResolution: Sendable, Equatable {
    /// No notification with the requested id existed (legacy `not_found` /
    /// "Notification not found", `data: {"id": …}`).
    case notFound
    /// The notification was removed. Carries the pre-removal snapshot used to
    /// build the success payload.
    case dismissed(ControlNotificationSnapshot)
}
