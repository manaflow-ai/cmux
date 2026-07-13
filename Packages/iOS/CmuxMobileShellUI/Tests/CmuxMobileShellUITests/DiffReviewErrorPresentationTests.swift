import CmuxDiffModel
import Testing

@testable import CmuxMobileShellUI

@Suite struct DiffReviewErrorPresentationTests {
    @Test func knownDomainErrorsHaveLocalizedMessages() {
        for error in [
            WorkspaceDiffError.notFound,
            .gitFailed,
            .timedOut,
            .staleRepository,
        ] {
            let message = DiffReviewErrorPresentation(error: error).message

            #expect(!message.isEmpty)
        }
    }

    @Test func unknownErrorsUseLocalizedFallback() {
        let message = DiffReviewErrorPresentation(
            error: WorkspaceDiffError.unavailable
        ).message

        #expect(!message.isEmpty)
    }
}
