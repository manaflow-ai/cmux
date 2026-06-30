import StackAuth
import Testing
@testable import CmuxMobileShellUI

@Suite struct SignInErrorPresentationTests {
    @Test func rateLimitedStackCodeUsesRateLimitMessageAndReason() {
        let presentation = SignInErrorPresentation()
        let error = StackAuthError(code: "RATE_LIMITED", message: "too many requests")

        #expect(presentation.failureReason(for: error) == "rate_limit")
        #expect(
            presentation.message(for: error)
                == "Too many attempts. Please wait a moment and try again."
        )
    }

    @Test func appleSignInSdkCodesUseAppleUnavailableMessage() {
        let presentation = SignInErrorPresentation()
        let codes = [
            "apple_signin_not_configured",
            "apple_signin_not_handled",
            "apple_signin_invalid_response",
            "apple_signin_failed",
            "apple_signin_not_interactive",
            "apple_signin_error",
        ]

        for code in codes {
            let error = StackAuthError(code: code, message: "apple failed")
            #expect(presentation.failureReason(for: error) == "oauth_error")
            #expect(
                presentation.message(for: error)
                    == "Apple Sign In is not available yet. Please use another sign-in method."
            )
        }
    }
}
