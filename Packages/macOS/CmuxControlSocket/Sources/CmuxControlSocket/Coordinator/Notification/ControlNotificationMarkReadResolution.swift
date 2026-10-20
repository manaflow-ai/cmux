/// The outcome of marking a single notification read by id (`notification.mark_read`
/// with an `id` selector).
///
/// The legacy body required the notification to exist before marking, reporting
/// not-found otherwise, and otherwise reported how many notifications flipped
/// from unread to read.
public enum ControlNotificationMarkReadResolution: Sendable, Equatable {
    /// No notification with the requested id existed (legacy `not_found` /
    /// "Notification not found", `data: {"id": …}`).
    case notFound
    /// The notification existed. Carries the count of notifications that flipped
    /// from unread to read (the legacy `marked_read`).
    case marked(count: Int)
}
