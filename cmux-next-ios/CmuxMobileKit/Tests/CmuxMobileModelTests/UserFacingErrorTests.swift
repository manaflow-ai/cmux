import Foundation
import Testing
@testable import CmuxMobileModel

/// Display sites say an error's own sentence or a plain fallback, never a Swift dump
/// (`LinkError(code: "timeout", …)`, "The operation couldn't be completed. (… error 1.)").
@Suite struct UserFacingErrorTests {
    private struct Opaque: Error { var code = "timeout" }
    private struct Said: LocalizedError { var errorDescription: String? }

    @Test func anErrorWithNoSentenceSaysTheFallback() {
        #expect(UserFacingError.message(Opaque()) == UserFacingError.generic)
        #expect(UserFacingError.message(Opaque(), fallback: "Couldn't copy that.") == "Couldn't copy that.")
        #expect(UserFacingError.message(CancellationError()) == UserFacingError.generic)
        #expect(!UserFacingError.message(Opaque()).contains("Opaque"))
    }

    @Test func aLocalizedErrorSaysItsOwnSentence() {
        #expect(UserFacingError.message(Said(errorDescription: "The Mac is busy.")) == "The Mac is busy.")
        #expect(UserFacingError.message(Said(errorDescription: "  ")) == UserFacingError.generic)
        #expect(UserFacingError.message(Said(errorDescription: nil)) == UserFacingError.generic)
        #expect(UserFacingError.message(Said(errorDescription: "Thing.Error(code: 1)")) == UserFacingError.generic)
    }

    @Test func networkErrorsSayWhatToDo() {
        #expect(UserFacingError.message(URLError(.notConnectedToInternet)) == "You're offline. Connect to the internet and try again.")
        #expect(UserFacingError.message(URLError(.timedOut)) == "The connection timed out. Try again.")
    }

    @Test func proseIsASentenceWithNoCodeOrMarkup() {
        #expect(UserFacingError.isProse("Couldn't connect. Try again."))
        #expect(!UserFacingError.isProse("token refresh failed"))
        #expect(!UserFacingError.isProse("permission.person_required"))
        #expect(!UserFacingError.isProse("HTTP 500"))
        #expect(!UserFacingError.isProse("<html><body>Bad Gateway</body></html>"))
        #expect(!UserFacingError.isProse(#"{"error":"x"}"#))
    }
}
