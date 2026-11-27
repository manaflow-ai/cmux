@testable import CmuxNextAccounts
import CmuxNextCloud
import CmuxNextDesign
import Testing

/// GitHub's install redirect back to the app: what the person reads when the completion did not connect.
/// Before, every answer but connected was dropped and the person saw nothing.
@MainActor @Suite
struct GitHubCompletionNoticeTests {
    typealias Notice = GitHubConnections.CompletionNotice

    @Test func aConnectedCompletionShowsNothing() {
        #expect(Notice(.connected) == nil)
    }

    @Test func aRefusalShowsTheAPIsMessageWithConnectAgain() throws {
        let notice = try #require(Notice(.refused(message: "integration state expired")))
        #expect(notice.message == "integration state expired")
        #expect(notice.retry == .connect)
        #expect(notice.retryTitle == Notice.connect)
        #expect(notice.tone == .error)
        let silent = try #require(Notice(.refused(message: nil)))
        #expect(silent.message == Notice.refused)
        #expect(silent.retry == .connect)
    }

    @Test func anOwnerRequestReadsAsPendingNotAnError() throws {
        let notice = try #require(Notice(.pendingApproval(message: "GitHub sent your request to install the cmux GitHub App to the organization's owners.")))
        #expect(notice.message == Notice.pending)
        #expect(notice.tone == .neutral)
        #expect(notice.retry == .connect)
        #expect(notice.retryTitle == Notice.connect)
    }

    @Test func noAnswerSaysCloudWasUnreachableAndRetriesTheSameLink() throws {
        let notice = try #require(Notice(.noAnswer))
        #expect(notice.message == Notice.noAnswer)
        #expect(notice.message.contains("cmux Cloud"))
        #expect(notice.retry == .sendAgain)
        #expect(notice.retryTitle == Notice.retryAgain)
        #expect(notice.tone == .error)
    }
}
