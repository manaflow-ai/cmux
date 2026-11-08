/// A bounded failure returned by the macOS user-notification service boundary.
public enum UserNotificationCenterFailure: Error, Equatable, Sendable {
    /// The framework entrypoint or its completion missed the configured deadline.
    case timedOut

    /// UserNotifications reported a system error after accepting the call.
    case system(String)
}
