/// The outcome of `notification.open`, preserving the legacy body's two
/// distinct `not_found` failures.
///
/// The legacy body looked up the notification, asked the app to open its
/// target, then re-read the (possibly mutated, e.g. now-read) notification for
/// the response payload.
public enum ControlNotificationOpenResolution: Sendable, Equatable {
    /// No notification with the requested id exists (legacy `not_found` /
    /// "Notification not found", `data: {"id": …}`).
    case notificationNotFound
    /// The notification exists but its target could not be opened (legacy
    /// `not_found` / "Notification target not found", `data:` the payload).
    /// Carries the post-open snapshot used to build that payload.
    case targetNotFound(ControlNotificationSnapshot)
    /// The notification's target was opened. Carries the post-open snapshot.
    case opened(ControlNotificationSnapshot)
}
