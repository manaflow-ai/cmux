/// Identifies what raised a notification authorization request, so the
/// coordinator can distinguish an explicit user action (the Settings button or
/// the Settings test) from an automatic request raised while delivering a
/// notification. Automatic requests are gated to fire at most once and may be
/// deferred until the app is active; manual requests always proceed.
public enum NotificationAuthorizationRequestOrigin: String, Sendable {
    /// An automatic request raised while delivering a notification.
    case notificationDelivery = "notification_delivery"
    /// A manual request from the Settings authorization button.
    case settingsButton = "settings_button"
    /// A manual request from the Settings "send test notification" action.
    case settingsTest = "settings_test"
}
