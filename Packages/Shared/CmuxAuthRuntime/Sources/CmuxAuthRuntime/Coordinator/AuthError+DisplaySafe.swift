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
        if error is CancellationError || Task.isCancelled {
            // A cancelled flow (the user backed out, or the sheet's task was
            // torn down) is not a failure to render. Mapping it to the generic
            // server error would flash "Something went wrong" after every
            // deliberate cancel. The `Task.isCancelled` arm matters because
            // URLSession-backed phases surface task cancellation as
            // `URLError(.cancelled)` (or a Stack transport error wrapping it),
            // not as `CancellationError`: this mapping always runs in the
            // cancelled flow's own catch, so any error caught on a cancelled
            // task is the cancellation, not an independent failure.
            self = .cancelled
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
                "RATE_LIMITED",
                "EMAIL_PASSWORD_MISMATCH",
                "USER_NOT_FOUND",
                "PASSKEY_AUTHENTICATION_FAILED",
                "PASSKEY_WEBAUTHN_ERROR",
                "INVALID_TOTP_CODE",
                "REDIRECT_URL_NOT_WHITELISTED",
                "OAUTH_PROVIDER_ACCOUNT_ID_ALREADY_USED_FOR_SIGN_IN",
                "INVALID_APPLE_CREDENTIALS",
                "APPLE_SIGNIN_NOT_CONFIGURED",
                "APPLE_SIGNIN_NOT_HANDLED",
                "APPLE_SIGNIN_INVALID_RESPONSE",
                "APPLE_SIGNIN_FAILED",
                "APPLE_SIGNIN_NOT_INTERACTIVE",
                "APPLE_SIGNIN_ERROR",
                "OAUTH_ERROR",
                "MISSING_CODE",
                "PARSE_ERROR",
                "INVALID_RESPONSE",
                "INVALID_URL":
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
}
