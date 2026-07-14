import Testing
@testable import CmuxGit

@Suite struct PullRequestReviewCommentTests {
    @Test func countsDistinctUnresolvedThreadIdentifiersWhenAvailable() throws {
        let payload = try PullRequestFixtureLoader().decode(
            PullRequestReviewCommentsPayload.self,
            named: "pull-request-comments"
        )
        #expect(payload.unresolvedThreadCount == 2)
    }

    @Test func missingThreadMetadataIsReportedAsUnavailable() {
        let payload = PullRequestReviewCommentsPayload(comments: [
            PullRequestReviewComment(threadId: "one", isResolved: nil),
        ])
        #expect(payload.unresolvedThreadCount == nil)
    }

    @Test func allKnownThreadsResolvedProducesZero() {
        let payload = PullRequestReviewCommentsPayload(comments: [
            PullRequestReviewComment(threadId: "one", isResolved: true),
            PullRequestReviewComment(threadId: "two", isResolved: true),
        ])
        #expect(payload.unresolvedThreadCount == 0)
    }
}
