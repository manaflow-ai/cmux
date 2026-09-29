import UserNotifications

/// Builds a native cmux request without an app-controlled delivery trigger.
///
/// macOS decides how long a banner remains visible. cmux keeps the
/// user-owned notification state in its stores until an explicit read or
/// dismissal path changes it, so callers must not add a time trigger here.
func makeCmuxNotificationRequest(
    identifier: String,
    content: UNNotificationContent
) -> UNNotificationRequest {
    UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
}
