public import UserNotifications

/// Pure mapping, labeling, and request-policy predicates for notification
/// authorization. These were lifted byte-faithfully off
/// `TerminalNotificationStore`; they take only value inputs
/// (`UNAuthorizationStatus`, `Bool`) and reach no app/AppDelegate state, so they
/// live on the already-extracted core state type.
///
/// `UNAuthorizationStatus` is a `Sendable` value enum from `UserNotifications`;
/// no `UNUserNotificationCenter` or other system object is referenced here.
extension NotificationAuthorizationState {
    /// Maps a `UNAuthorizationStatus` to the resolved core state.
    public static func authorizationState(
        from status: UNAuthorizationStatus
    ) -> NotificationAuthorizationState {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }

    /// A short, debug-log-only label for a raw `UNAuthorizationStatus`. Not
    /// user-facing, not localized.
    public static func authorizationStatusLabel(
        _ status: UNAuthorizationStatus
    ) -> String {
        switch status {
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
            return "unknown(\(status.rawValue))"
        }
    }

    /// Whether an automatic authorization request should be deferred because the
    /// status is undetermined while the app is not active.
    public static func shouldDeferAutomaticAuthorizationRequest(
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        status == .notDetermined && !isAppActive
    }

    /// Whether an authorization request should proceed. A manual request always
    /// proceeds; an automatic request proceeds only if it has not already been
    /// made.
    public static func shouldRequestAuthorization(
        isAutomaticRequest: Bool,
        hasRequestedAutomaticAuthorization: Bool
    ) -> Bool {
        guard isAutomaticRequest else { return true }
        return !hasRequestedAutomaticAuthorization
    }
}
