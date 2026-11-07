/// The effective authorization outcome used by notification delivery and settings.
public enum NotificationAuthorizationState: Equatable, Sendable {
    /// Authorization is unavailable or the service returned an unknown status.
    case unknown
    /// The user has not answered the authorization prompt.
    case notDetermined
    /// Native notifications are allowed.
    case authorized
    /// The user denied notification permission.
    case denied
    /// Notifications may be delivered quietly under provisional permission.
    case provisional
    /// Temporary notification permission is active.
    case ephemeral

    /// The permission label presented in settings.
    public var statusLabel: String {
        switch self {
        case .unknown, .notDetermined: return "Not Requested"
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .provisional: return "Deliver Quietly"
        case .ephemeral: return "Temporary"
        }
    }

    /// Whether this state permits native delivery.
    public var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: return true
        case .unknown, .notDetermined, .denied: return false
        }
    }

    /// Maps the service's authorization snapshot to the effective permission state.
    /// - Parameter status: The snapshot returned by the notification service.
    public init(status: UserNotificationAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .notDetermined: self = .notDetermined
        case .provisional: self = .provisional
        case .ephemeral: self = .ephemeral
        case .unknown: self = .unknown
        }
    }
}
