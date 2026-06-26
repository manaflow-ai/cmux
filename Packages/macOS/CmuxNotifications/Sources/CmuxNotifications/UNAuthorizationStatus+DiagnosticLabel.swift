public import UserNotifications

public extension UNAuthorizationStatus {
    /// A stable, human-readable label for the raw system authorization status,
    /// used in notification authorization diagnostic logging. Distinct from
    /// ``NotificationAuthorizationState/statusLabel``, which labels the app's
    /// mapped state for the Settings UI.
    var diagnosticLabel: String {
        switch self {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown(\(rawValue))"
        }
    }
}
