/// Failures that prevent a backend-only host connection.
public enum BackendOnlyHostConnectionError: Error, Equatable, Sendable {
    /// The app bundle has no valid identifier.
    case invalidBundleIdentifier
    /// The client identity could not be established.
    case invalidClientIdentity
    /// Backend service activation is disabled.
    case disabled
    /// The service needs user approval.
    case approvalRequired
    /// The required backend bundle item is absent.
    case missingBundleItem
    /// The registered backend service was not found.
    case serviceNotFound
    /// The backend did not become ready.
    case backendUnavailable
    /// The session does not allow mutations.
    case readOnly
}
