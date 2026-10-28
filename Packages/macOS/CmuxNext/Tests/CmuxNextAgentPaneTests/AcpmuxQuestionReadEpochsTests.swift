import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Correlation is a pure one-use primitive; it does not create question or person authority.
struct AcpmuxQuestionReadEpochsTests {
    @Test func tokenRedeemsOnceAndRejectsUnknown() {
        var reads = AcpmuxQuestionReadEpochs()
        #expect(reads.issue(7))
        #expect(reads.redeem(7))
        #expect(!reads.redeem(7))
        #expect(!reads.redeem(8))
    }

    @Test func invalidationRevokesPriorEpochAndAcceptsOnlyNewIssue() {
        var reads = AcpmuxQuestionReadEpochs()
        #expect(reads.issue(7))
        reads.invalidate()
        #expect(!reads.redeem(7))
        #expect(reads.issue(8))
        #expect(reads.redeem(8))
    }

    @Test func cancellationRevokesWithoutAdvancingEpoch() {
        var reads = AcpmuxQuestionReadEpochs()
        #expect(reads.issue(7))
        reads.cancel(7)
        #expect(!reads.redeem(7))
        #expect(reads.issue(8))
        #expect(reads.redeem(8))
    }

    @Test func duplicateAndBoundedIssuesCannotReplaceOutstandingToken() {
        var reads = AcpmuxQuestionReadEpochs()
        #expect(reads.issue(7))
        #expect(!reads.issue(7))
        for token in 8...AcpmuxQuestionReadEpochs.limit {
            #expect(reads.issue(token))
        }
        #expect(!reads.issue(AcpmuxQuestionReadEpochs.limit + 1))
        #expect(reads.redeem(7))
        #expect(reads.issue(AcpmuxQuestionReadEpochs.limit + 1))
    }
}
