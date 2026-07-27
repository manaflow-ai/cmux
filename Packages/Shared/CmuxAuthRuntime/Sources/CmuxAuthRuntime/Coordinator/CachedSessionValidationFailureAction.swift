import Foundation

/// How the coordinator should recover when validating a cached session fails.
public enum CachedSessionValidationFailureAction: String, Equatable, Sendable {
    /// Clear the persisted session and require a fresh sign-in.
    case clearSession
    /// Keep the cached session (transient failure; do not sign out).
    case preserveCachedSession
}
