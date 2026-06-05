import Foundation
import StackAuth

/// Maps raw backend errors to the display-safe ``AuthError`` vocabulary.
///
/// Centralizes the Stack-error-code translation that the sign-in UI and the
/// session-restore path both rely on, so a single value (no global state) owns
/// the mapping and tests can exercise it directly. The type is a pure value;
/// construct it freely (`AuthErrorMapper()`).
public struct AuthErrorMapper: Sendable {
    /// Creates an error mapper.
    public init() {}

    /// Translate an arbitrary error into a display-safe ``AuthError`` or a
    /// preserved Stack error.
    ///
    /// Stack error codes the sign-in UI renders specifically (schema, OTP, rate
    /// limit, etc.) are returned unchanged so the view can localize them; auth
    /// failures collapse to ``AuthError`` cases; URL errors become
    /// ``AuthError/networkError``; everything else becomes a generic server
    /// error.
    /// - Parameter error: The raw error from a sign-in/session call.
    /// - Returns: A display-safe error.
    public func displaySafe(_ error: any Error) -> any Error {
        if let authError = error as? AuthError {
            return authError
        }
        if let stackError = error as? any StackAuthErrorProtocol {
            switch stackError.code.uppercased() {
            case "OAUTH_CANCELLED":
                return AuthError.cancelled
            case
                "SCHEMA_ERROR",
                "USER_EMAIL_ALREADY_EXISTS",
                "VERIFICATION_CODE_ERROR",
                "INVALID_OTP",
                "OTP_EXPIRED",
                "RATE_LIMIT",
                "EMAIL_PASSWORD_MISMATCH",
                "USER_NOT_FOUND",
                "PASSKEY_AUTHENTICATION_FAILED",
                "PASSKEY_WEBAUTHN_ERROR",
                "INVALID_TOTP_CODE",
                "REDIRECT_URL_NOT_WHITELISTED",
                "OAUTH_PROVIDER_ACCOUNT_ID_ALREADY_USED_FOR_SIGN_IN",
                "INVALID_APPLE_CREDENTIALS":
                return error
            case "UNAUTHORIZED", "INVALID_TOKEN", "TOKEN_EXPIRED":
                return AuthError.unauthorized
            default:
                return AuthError.serverError(0, "auth_failed")
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return AuthError.networkError
        }
        return AuthError.serverError(0, "auth_failed")
    }

    /// Decide how to recover when validating a cached session fails.
    ///
    /// Only a hard `unauthorized` clears the cached session; transient failures
    /// preserve it so a flaky network does not sign the user out.
    /// - Parameter error: The validation failure.
    /// - Returns: The recovery action.
    public func cachedSessionValidationFailureAction(
        for error: any Error
    ) -> CachedSessionValidationFailureAction {
        if case AuthError.unauthorized = displaySafe(error) {
            return .clearSession
        }
        return .preserveCachedSession
    }
}

/// How the coordinator should recover when validating a cached session fails.
public enum CachedSessionValidationFailureAction: String, Equatable, Sendable {
    /// Clear the persisted session and require a fresh sign-in.
    case clearSession
    /// Keep the cached session (transient failure; do not sign out).
    case preserveCachedSession
}
