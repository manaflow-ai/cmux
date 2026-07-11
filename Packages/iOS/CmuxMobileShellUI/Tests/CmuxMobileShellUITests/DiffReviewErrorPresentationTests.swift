import CmuxMobileRPC
import Testing

@testable import CmuxMobileShellUI

@Suite struct DiffReviewErrorPresentationTests {
    @Test func knownRPCErrorsDoNotExposeServerEnglish() {
        for code in ["not_found", "git_failed", "stale_repository"] {
            let message = DiffReviewErrorPresentation.message(
                for: MobileShellConnectionError.rpcError(code, "UNLOCALIZED SERVER MESSAGE")
            )

            #expect(!message.isEmpty)
            #expect(!message.contains("UNLOCALIZED SERVER MESSAGE"))
        }
    }

    @Test func unknownErrorsUseLocalizedFallback() {
        let message = DiffReviewErrorPresentation.message(
            for: MobileShellConnectionError.rpcError("future_code", "UNLOCALIZED SERVER MESSAGE")
        )

        #expect(!message.isEmpty)
        #expect(!message.contains("UNLOCALIZED SERVER MESSAGE"))
    }
}
