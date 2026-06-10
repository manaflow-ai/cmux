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
    /// The session is no longer valid and the user must sign in again.
    case unauthorized
    /// A generic credential failure (e.g. wrong email/password).
    case authFailure
    /// The user cancelled an interactive flow (e.g. dismissed the OAuth sheet).
    /// Surfaces no description so callers can silently ignore it.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .offline:
            return String(
                localized: "auth.error.offline",
                defaultValue: "No internet connection. Connect to Wi-Fi or cellular and try again.",
                bundle: .main
            )
        case .networkError:
            return String(
                localized: "auth.error.network_error",
                defaultValue: "Network error. Please check your connection.",
                bundle: .main
            )
        case .timedOut:
            return String(
                localized: "auth.error.timed_out",
                defaultValue: "Sign-in timed out. Check your connection and try again.",
                bundle: .main
            )
        case .serverError:
            return String(
                localized: "auth.error.server_error",
                defaultValue: "Something went wrong. Please try again.",
                bundle: .main
            )
        case .invalidCode:
            return String(
                localized: "auth.error.invalid_code_short",
                defaultValue: "Invalid code. Please try again.",
                bundle: .main
            )
        case .unauthorized:
            return String(
                localized: "auth.error.unauthorized",
                defaultValue: "Session expired. Please sign in again.",
                bundle: .main
            )
        case .authFailure:
            return String(
                localized: "auth.error.wrong_password",
                defaultValue: "Incorrect email or password.",
                bundle: .main
            )
        case .cancelled:
            return nil
        }
    }
}
