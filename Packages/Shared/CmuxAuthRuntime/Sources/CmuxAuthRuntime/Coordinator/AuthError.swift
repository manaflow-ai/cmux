public import Foundation

/// The shared, localized error vocabulary for cmux authentication flows.
///
/// Lifted out of the iOS-only `CmuxMobileAuth` package so both the macOS and iOS
/// apps share one error type. Error descriptions resolve from the app target's
/// `Localizable.xcstrings` via `Bundle.main`, matching the strings the iOS app
/// previously surfaced through `CMUXMobileCore.L10n`.
public enum AuthError: Error, LocalizedError, Equatable, Sendable {
    /// The device has no network connectivity; the flow failed fast.
    case offline
    /// A transport-level network failure (timeout, DNS, TLS, etc.).
    case networkError
    /// A bounded sign-in phase hit its deadline without completing or failing.
    /// Replaces the prior behavior of waiting forever on a call (or a system
    /// auth callback) that never resolves.
    case timedOut
    /// The auth server returned a non-success status. Carries the HTTP status
    /// code (or `0` when unknown) and a stable machine-readable reason.
    case serverError(Int, String)
    /// The supplied magic-link / OTP code was missing or rejected.
    case invalidCode
    /// The hosted sign-in callback returned to the app but did not contain a
    /// token payload or did not match the active attempt.
    case invalidCallback
    /// The OS/browser auth session closed before a valid callback reached cmux.
    /// Carries a stable diagnostic reason for logs/tests; UI copy stays generic.
    case browserSignInFailed(String)
    /// The session is no longer valid and the user must sign in again.
    case unauthorized
    /// A generic credential failure (e.g. wrong email/password).
    case authFailure
    /// The user cancelled an interactive flow (e.g. dismissed the OAuth sheet).
    /// Surfaces no description so callers can silently ignore it.
    case cancelled
    /// The sign-in service answered 429 (too many requests from this
    /// network). The session is untouched; the flow retries on its own.
    case rateLimited

    public var errorDescription: String? {
        switch self {
        case .offline:
            return authLocalized(
                "auth.error.offline",
                "No internet connection. Connect to Wi-Fi or cellular and try again."
            )
        case .networkError:
            return authLocalized("auth.error.network_error", "Network error. Please check your connection.")
        case .timedOut:
            return authLocalized(
                "auth.error.timed_out",
                "Sign-in timed out. Check your connection and try again."
            )
        case .serverError:
            return authLocalized("auth.error.server_error", "Something went wrong. Please try again.")
        case .invalidCode:
            return authLocalized("auth.error.invalid_code_short", "Invalid code. Please try again.")
        case .invalidCallback:
            return authLocalized(
                "auth.error.invalid_callback",
                "The sign-in callback was invalid. Try signing in again."
            )
        case .browserSignInFailed:
            return authLocalized(
                "auth.error.browser_sign_in_failed",
                "Could not complete browser sign-in. Try again or open sign-in in your browser."
            )
        case .unauthorized:
            return authLocalized("auth.error.unauthorized", "Session expired. Please sign in again.")
        case .authFailure:
            return authLocalized("auth.error.wrong_password", "Incorrect email or password.")
        case .cancelled:
            return nil
        case .rateLimited:
            return authLocalized(
                "auth.error.rate_limited",
                "Too many sign-in requests from this network. cmux retries automatically."
            )
        }
    }
}

private func authLocalized(_ key: String, _ fallback: String) -> String {
#if canImport(Darwin)
    String(localized: key, defaultValue: fallback, bundle: .main)
#else
    fallback
#endif
}
