/// The app's view of the system notification authorization status, mapped from
/// `UNAuthorizationStatus` into the states the notification UI distinguishes.
///
/// Pure value type: it carries no live state and only derives display/decision
/// values from its own case, so it lives in the notifications package and is
/// shared across the store, settings, and the notification queue.
public enum NotificationAuthorizationState: Equatable, Sendable {
    /// Status has not been resolved yet (no system query has completed).
    case unknown
    /// The user has not been asked for notification permission.
    case notDetermined
    /// Notifications are allowed.
    case authorized
    /// Notifications are denied.
    case denied
    /// Notifications are delivered quietly (provisional authorization).
    case provisional
    /// Notifications are temporarily authorized (App Clip-style ephemeral grant).
    case ephemeral

    /// A human-readable label for the authorization status, shown in Settings.
    public var statusLabel: String {
        switch self {
        case .unknown, .notDetermined:
            return "Not Requested"
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .provisional:
            return "Deliver Quietly"
        case .ephemeral:
            return "Temporary"
        }
    }

    /// Whether the system will deliver notifications in this state.
    public var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .unknown, .notDetermined, .denied:
            return false
        }
    }
}
