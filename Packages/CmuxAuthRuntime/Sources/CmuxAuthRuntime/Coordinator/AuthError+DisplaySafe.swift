import Foundation
import StackAuth

extension AuthError {
    /// Translate a raw backend error into the display-safe ``AuthError``
    /// vocabulary, or `nil` when the original error should be surfaced
    /// unchanged.
    ///
    /// Stack error codes the sign-in UI renders specifically (schema, OTP,
    /// rate limit, etc.) yield `nil` so the view can localize them; auth
    /// failures collapse to ``AuthError`` cases; URL errors become
    /// ``AuthError/networkError``; everything else becomes a generic server
    /// error. Callers throw `AuthError(displaySafe: error) ?? error`.
    /// - Parameter error: The raw error from a sign-in/session call.
    public init?(displaySafe error: any Error) {
        if let authError = error as? AuthError {
            self = authError
            return
        }
        if let stackError = error as? any StackAuthErrorProtocol {
            switch stackError.code.uppercased() {
            case "OAUTH_CANCELLED":
                self = .cancelled
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
                // Already display-safe; the sign-in UI renders these codes.
                return nil
            case "UNAUTHORIZED", "INVALID_TOKEN", "TOKEN_EXPIRED":
                self = .unauthorized
            default:
                self = .serverError(0, "auth_failed")
            }
            return
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            self = .networkError
            return
        }
        self = .serverError(0, "auth_failed")
    }

    /// How the coordinator should recover when validating a cached session
    /// fails with this error: only a hard ``AuthError/unauthorized`` clears
    /// the cached session; transient failures preserve it so a flaky network
    /// does not sign the user out.
    public var cachedSessionValidationFailureAction: CachedSessionValidationFailureAction {
        self == .unauthorized ? .clearSession : .preserveCachedSession
    }

    /// Returns a token-free auth error description suitable for diagnostics.
    ///
    /// Display-safe ``AuthError`` values use their localized descriptions.
    /// Stack errors that the sign-in UI renders specifically keep only their
    /// public code, while unknown backend details collapse through
    /// ``init(displaySafe:)`` before they are described.
    /// - Parameter error: The raw or already display-safe auth error.
    /// - Returns: A diagnostics-safe description, or `nil` for cancellations.
    static func diagnosticsDescription(for error: any Error) -> String? {
        if let displayError = AuthError(displaySafe: error) {
            if displayError == .cancelled {
                return nil
            }
            return displayError.localizedDescription
        }
        if let stackError = error as? any StackAuthErrorProtocol {
            return "code=\(stackError.code)"
        }
        return error.localizedDescription
    }
}
