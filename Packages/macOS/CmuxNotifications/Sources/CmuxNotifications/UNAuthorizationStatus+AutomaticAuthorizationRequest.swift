public import UserNotifications

public extension UNAuthorizationStatus {
    /// Whether cmux should defer an automatic notification authorization request
    /// for this status until the app becomes active. The first system prompt
    /// (status `.notDetermined`) is held back while the app is in the
    /// background, so the user sees it when cmux is frontmost rather than
    /// unprompted. Any other status never defers.
    func shouldDeferAutomaticAuthorizationRequest(isAppActive: Bool) -> Bool {
        self == .notDetermined && !isAppActive
    }
}
