public import UserNotifications

/// A low-level add entrypoint supplied to the serialized notification service.
public typealias UserNotificationAddOperation = @Sendable (
    _ request: UNNotificationRequest,
    _ completion: @escaping @Sendable ((any Error)?) -> Void
) -> Void

/// Bounded access to every UserNotifications operation used by the macOS app.
public protocol UserNotificationCenterServing: UserNotificationCenterConfiguring, Sendable {
    /// Returns the app's current notification authorization status.
    func authorizationStatus() async -> Result<
        UserNotificationAuthorizationStatus,
        UserNotificationCenterFailure
    >

    /// Requests alert and sound authorization without blocking the caller's executor.
    /// - Parameter options: The authorization capabilities requested from macOS.
    func requestAuthorization(
        options: UNAuthorizationOptions
    ) async -> Result<Bool, UserNotificationCenterFailure>

    /// Adds one notification request without blocking the caller's executor.
    /// - Parameter request: The immutable request to submit to macOS.
    func add(
        _ request: UNNotificationRequest
    ) async -> Result<Void, UserNotificationCenterFailure>

    /// Removes delivered notifications matching the supplied identifiers.
    /// - Parameter identifiers: Request identifiers to remove.
    func removeDeliveredNotifications(
        withIdentifiers identifiers: [String]
    ) async -> Result<Void, UserNotificationCenterFailure>

    /// Removes pending notification requests matching the supplied identifiers.
    /// - Parameter identifiers: Request identifiers to remove.
    func removePendingNotificationRequests(
        withIdentifiers identifiers: [String]
    ) async -> Result<Void, UserNotificationCenterFailure>
}
