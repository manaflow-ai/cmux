import Testing
@testable import CmuxGit

@Suite struct PullRequestReviewCommentTests {
    @Test func countsDistinctUnresolvedThreadIdentifiersWhenAvailable() throws {
        let payload = PullRequestReviewCommentsPayload(comments: [
            PullRequestReviewComment(threadId: "thread-1", isResolved: false),
            PullRequestReviewComment(threadId: "thread-1", isResolved: false),
            PullRequestReviewComment(threadId: "thread-2", isResolved: true),
            PullRequestReviewComment(threadId: "thread-3", isResolved: false),
        ])
        #expect(payload.unresolvedThreadCount == 2)
    }

    @Test func capturedGitHubCLICommentsReportThreadCountAsUnavailable() throws {
        let payload = try PullRequestFixtureLoader().decode(
            PullRequestReviewCommentsPayload.self,
            named: "pull-request-comments"
        )
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
