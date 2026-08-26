import UserNotifications

/// A sendable snapshot of the authorization status returned by UserNotifications.
public enum UserNotificationAuthorizationStatus: Equatable, Sendable {
    /// The user has not answered the authorization prompt.
    case notDetermined

    /// The user denied notification authorization.
    case denied

    /// The app is authorized to post notifications.
    case authorized

    /// The app has provisional notification authorization.
    case provisional

    /// The app has ephemeral notification authorization.
    case ephemeral

    /// The framework returned a status newer than this version of cmux understands.
    case unknown(Int)

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        case .provisional:
            self = .provisional
        case .ephemeral:
            self = .ephemeral
        @unknown default:
            self = .unknown(status.rawValue)
        }
    }
}
