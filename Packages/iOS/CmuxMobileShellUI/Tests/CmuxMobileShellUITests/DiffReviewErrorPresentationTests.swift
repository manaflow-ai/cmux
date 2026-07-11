import CmuxMobileRPC
import Testing

@testable import CmuxMobileShellUI

@Suite struct DiffReviewErrorPresentationTests {
    @Test func knownRPCErrorsDoNotExposeServerEnglish() {
        for code in ["not_found", "git_failed", "git_timeout", "stale_repository"] {
            let message = DiffReviewErrorPresentation(
                error: MobileShellConnectionError.rpcError(code, "UNLOCALIZED SERVER MESSAGE")
            ).message

            #expect(!message.isEmpty)
            #expect(!message.contains("UNLOCALIZED SERVER MESSAGE"))
        }
    }

    @Test func unknownErrorsUseLocalizedFallback() {
        let message = DiffReviewErrorPresentation(
            error: MobileShellConnectionError.rpcError("future_code", "UNLOCALIZED SERVER MESSAGE")
        ).message

        #expect(!message.isEmpty)
        #expect(!message.contains("UNLOCALIZED SERVER MESSAGE"))
    }
}
