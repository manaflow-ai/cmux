import Foundation
import StackAuth
import Testing
@testable import CmuxAuthRuntime

@Suite struct AuthErrorDisplaySafeTests {
    @Test func preservesRenderableStackCodes() {
        let preserved = [
            "SCHEMA_ERROR", "USER_EMAIL_ALREADY_EXISTS", "VERIFICATION_CODE_ERROR",
            "INVALID_OTP", "OTP_EXPIRED", "RATE_LIMIT", "EMAIL_PASSWORD_MISMATCH",
            "USER_NOT_FOUND", "INVALID_TOTP_CODE",
        ]
        for code in preserved {
            // nil means "surface the original error unchanged".
            #expect(AuthError(displaySafe: StackAuthError(code: code, message: "message")) == nil)
        }
    }

    @Test func passesThroughExistingAuthErrors() {
        #expect(AuthError(displaySafe: AuthError.offline) == .offline)
        #expect(AuthError(displaySafe: AuthError.invalidCode) == .invalidCode)
    }

    @Test func mapsOAuthCancellationToCancelled() {
        #expect(AuthError(displaySafe: StackAuthError(code: "oauth_cancelled", message: "cancelled")) == .cancelled)
    }

    @Test func mapsUnknownCodesToGenericServerError() {
        #expect(
            AuthError(displaySafe: StackAuthError(code: "UNEXPECTED", message: "raw server detail"))
                == .serverError(0, "auth_failed")
        )
    }

    @Test func mapsURLErrorsToNetworkError() {
        let urlError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(AuthError(displaySafe: urlError) == .networkError)
    }

    @Test func mapsAuthTokenCodesToUnauthorized() {
        for code in ["UNAUTHORIZED", "INVALID_TOKEN", "TOKEN_EXPIRED"] {
            #expect(AuthError(displaySafe: StackAuthError(code: code, message: "x")) == .unauthorized)
        }
    }

    @Test func cachedSessionValidationClearsOnlyDefinitiveUnauthorized() {
        #expect(
            AuthError(displaySafe: StackAuthError(code: "UNAUTHORIZED", message: "expired"))?
                .cachedSessionValidationFailureAction == .clearSession
        )
        #expect(
            AuthError(displaySafe: StackAuthError(code: "INVALID_TOKEN", message: "invalid"))?
                .cachedSessionValidationFailureAction == .clearSession
        )
        #expect(
            AuthError(displaySafe: AuthError.networkError)?
                .cachedSessionValidationFailureAction == .preserveCachedSession
        )
        // Preserved (renderable) codes map to nil; the coordinator treats nil
        // as preserve-cached-session.
        #expect(AuthError(displaySafe: StackAuthError(code: "RATE_LIMIT", message: "try later")) == nil)
    }
}
