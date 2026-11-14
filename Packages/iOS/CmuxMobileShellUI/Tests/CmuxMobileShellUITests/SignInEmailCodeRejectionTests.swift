import Foundation
import StackAuth
import Testing
@testable import CmuxMobileShellUI

/// The sign-in service rejects a typed email code with one of these errors.
/// Release builds used to show every one of them as "Something went wrong.
/// Please try again.", which gave a user stuck on email sign-in nothing to act
/// on (and retrying the same code never works).
@Suite struct SignInEmailCodeRejectionTests {
    private let presentation = SignInErrorPresentation()

    @Test func wrongOrSupersededCodeSaysTheCodeIsInvalid() {
        let error = StackAuthError(code: "VERIFICATION_CODE_NOT_FOUND", message: "not found")

        #expect(presentation.message(for: error) == "Invalid code. Please check and try again.")
        #expect(presentation.failureReason(for: error) == "invalid_code")
    }

    @Test func expiredCodeAsksForANewOne() {
        let error = StackAuthError(code: "VERIFICATION_CODE_EXPIRED", message: "expired")

        #expect(presentation.message(for: error) == "Code expired. Please request a new one.")
        #expect(presentation.failureReason(for: error) == "code_expired")
    }

    @Test func usedCodeAsksForANewOne() {
        let error = StackAuthError(code: "VERIFICATION_CODE_ALREADY_USED", message: "used")

        #expect(
            presentation.message(for: error)
                == "This code was already used. Please request a new one."
        )
        #expect(presentation.failureReason(for: error) == "code_used")
    }

    @Test func tooManyWrongCodesAsksForANewOne() {
        let error = StackAuthError(
            code: "VERIFICATION_CODE_MAX_ATTEMPTS_REACHED",
            message: "max attempts"
        )

        #expect(
            presentation.message(for: error)
                == "Too many incorrect codes. Please request a new one."
        )
        #expect(presentation.failureReason(for: error) == "code_attempts_exhausted")
    }
}
