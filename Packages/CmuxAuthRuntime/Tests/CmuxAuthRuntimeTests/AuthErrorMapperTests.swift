import Foundation
import StackAuth
import Testing
@testable import CmuxAuthRuntime

@Suite struct AuthErrorMapperTests {
    private let mapper = AuthErrorMapper()

    @Test func preservesRenderableStackCodes() throws {
        let preserved = [
            "SCHEMA_ERROR", "USER_EMAIL_ALREADY_EXISTS", "VERIFICATION_CODE_ERROR",
            "INVALID_OTP", "OTP_EXPIRED", "RATE_LIMIT", "EMAIL_PASSWORD_MISMATCH",
            "USER_NOT_FOUND", "INVALID_TOTP_CODE",
        ]
        for code in preserved {
            let mapped = mapper.displaySafe(StackAuthError(code: code, message: "message"))
            let stackError = try #require(mapped as? any StackAuthErrorProtocol)
            #expect(stackError.code == code)
        }
    }

    @Test func mapsOAuthCancellationToCancelled() {
        let cancelled = mapper.displaySafe(StackAuthError(code: "oauth_cancelled", message: "cancelled"))
        guard case AuthError.cancelled = cancelled else {
            Issue.record("Expected OAuth cancellation to map to AuthError.cancelled")
            return
        }
    }

    @Test func mapsUnknownCodesToGenericServerError() {
        let unknown = mapper.displaySafe(StackAuthError(code: "UNEXPECTED", message: "raw server detail"))
        guard case AuthError.serverError(0, "auth_failed") = unknown else {
            Issue.record("Expected unknown code to map to generic server error")
            return
        }
    }

    @Test func mapsAuthTokenCodesToUnauthorized() {
        for code in ["UNAUTHORIZED", "INVALID_TOKEN", "TOKEN_EXPIRED"] {
            let mapped = mapper.displaySafe(StackAuthError(code: code, message: "x"))
            guard case AuthError.unauthorized = mapped else {
                Issue.record("Expected \(code) to map to unauthorized")
                return
            }
        }
    }

    @Test func cachedSessionValidationClearsOnlyDefinitiveUnauthorized() {
        #expect(
            mapper.cachedSessionValidationFailureAction(
                for: StackAuthError(code: "UNAUTHORIZED", message: "expired")
            ) == .clearSession
        )
        #expect(
            mapper.cachedSessionValidationFailureAction(
                for: StackAuthError(code: "INVALID_TOKEN", message: "invalid")
            ) == .clearSession
        )
        #expect(
            mapper.cachedSessionValidationFailureAction(
                for: AuthError.networkError
            ) == .preserveCachedSession
        )
        #expect(
            mapper.cachedSessionValidationFailureAction(
                for: StackAuthError(code: "RATE_LIMIT", message: "try later")
            ) == .preserveCachedSession
        )
    }
}
