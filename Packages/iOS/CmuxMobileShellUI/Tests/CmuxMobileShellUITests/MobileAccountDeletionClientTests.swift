import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileAccountDeletionClientTests {
    @Test func parserTreatsQueuedDeletionAsAccepted() throws {
        let result = try MobileAccountDeletionResponseParser().deletionResult(
            statusCode: 202,
            data: Data(#"{"ok":true,"status":"pending"}"#.utf8)
        )

        #expect(result == .accepted(.pending))
    }

    @Test func parserTreatsCompletedDeletionAsCompleted() throws {
        let result = try MobileAccountDeletionResponseParser().deletionResult(
            statusCode: 200,
            data: Data(#"{"ok":true,"status":"completed"}"#.utf8)
        )

        #expect(result == .completed)
    }

    @Test func parserRejectsMalformedSuccessPayloads() {
        #expect(throws: MobileAccountDeletionError.invalidResponse) {
            _ = try MobileAccountDeletionResponseParser().deletionResult(
                statusCode: 202,
                data: Data(#"{"ok":true}"#.utf8)
            )
        }
    }

    @Test func parserTreatsFailedWorkflowAsWorkflowFailure() {
        #expect(throws: MobileAccountDeletionError.workflowFailed) {
            _ = try MobileAccountDeletionResponseParser().deletionResult(
                statusCode: 200,
                data: Data(#"{"ok":true,"status":"failed"}"#.utf8)
            )
        }
    }
}
