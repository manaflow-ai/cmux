/// The resolved notification-authorization state used to decide whether a
/// terminal notification may be delivered.
///
/// This is a pure value type: it carries no reference to `UNUserNotificationCenter`
/// or any other system object. The app-side mapper
/// `authorizationState(from: UNAuthorizationStatus)` (which is coupled to
/// `UserNotifications`) feeds this enum; this type only owns the resolved state
/// and the two values derived from it.
///
/// `statusLabel` strings appear only in debug-log interpolation, never in
/// localized UI, so they are plain English literals.
public enum NotificationAuthorizationState: Equatable, Sendable {
    /// The current state has not yet been determined (initial value).
    case unknown
    /// The user has not yet been asked for notification authorization.
    case notDetermined
    /// The user authorized notifications.
    case authorized
    /// The user denied notifications.
    case denied
    /// Provisional authorization (notifications delivered quietly).
    case provisional
    /// Ephemeral (temporary) authorization, e.g. for App Clips.
    case ephemeral

    /// A short, debug-log-only label for the state. Not user-facing, not localized.
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

    /// Whether a notification may be delivered in this state.
    public var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .unknown, .notDetermined, .denied:
            return false
        }
    }
}
