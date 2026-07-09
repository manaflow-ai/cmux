/// The pure gate deciding whether cmux issues a system notification
/// authorization request. A manual request (from the Settings button) always
/// proceeds; an automatic request, raised while delivering a notification,
/// proceeds only the first time so the system prompt is never shown twice on
/// its own.
public struct NotificationAuthorizationRequestGate: Equatable, Sendable {
    /// Whether the pending request was raised automatically during delivery
    /// rather than by an explicit user action.
    public let isAutomaticRequest: Bool
    /// Whether an automatic authorization request has already been issued.
    public let hasRequestedAutomaticAuthorization: Bool

    /// Creates a request gate from the automatic-request flags.
    public init(isAutomaticRequest: Bool, hasRequestedAutomaticAuthorization: Bool) {
        self.isAutomaticRequest = isAutomaticRequest
        self.hasRequestedAutomaticAuthorization = hasRequestedAutomaticAuthorization
    }

    /// Whether the authorization request should be issued. Manual requests
    /// always pass; an automatic request passes only when no automatic request
    /// has been made yet.
    public var shouldRequestAuthorization: Bool {
        guard isAutomaticRequest else { return true }
        return !hasRequestedAutomaticAuthorization
    }
}
