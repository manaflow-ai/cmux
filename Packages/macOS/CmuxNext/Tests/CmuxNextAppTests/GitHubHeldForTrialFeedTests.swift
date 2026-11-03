import CmuxNextFeed
import Foundation
import Testing

/// Needs you: a pull request the user opened that waits on their own trial (open, authored by
/// them, carrying the `hold` label, e.g. a structural sidebar change held for a dogfood build) is
/// an open request in the Feed, so it sits in the pinned Needs you section until it lands or the
/// hold comes off.
@MainActor @Suite(.serialized)
struct GitHubHeldForTrialFeedTests {
    final class Owner: FeedPostingSource {
        var posted: [FeedItem] = []
        func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void) {}
        func send(_ intent: FeedIntent) {}
        func stop() {}
        func post(_ item: FeedItem) { posted.append(item) }
    }

    nonisolated struct FakeGitHub: GitHubFeedAPI {
        static let date = Date(timeIntervalSince1970: 1_700_000_000)
        func notifications(etag: String?) async throws -> GitHubAPIResponse<[GitHubNotification]> { GitHubAPIResponse(value: []) }
        func reviewRequests(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]> { GitHubAPIResponse(value: []) }
        func heldForTrial(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]> {
            GitHubAPIResponse(value: [GitHubReviewRequest(
                id: 30817, number: 30817, title: "Spaces switcher", htmlURL: "https://github.com/acme/app/pull/30817",
                repository: .init(fullName: "acme/app"), user: .init(login: "me"), state: "open", updatedAt: Self.date)])
        }
    }

    @Test func aPullRequestHeldForYourTrialIsAnOpenNeedsYouRequest() async throws {
        let owner = Owner()
        let source = GitHubFeedSource(owner: owner, client: FakeGitHub(), now: { FakeGitHub.date })
        await source.refresh()
        let item = try #require(owner.posted.first { $0.dedupeKey == "github:held:acme/app:30817" })
        #expect(item.isOpenRequest)
        #expect(item.body == "acme/app#30817")
        #expect(item.prompt == .review(.init(subject: .pr, ref: "https://github.com/acme/app/pull/30817")))
        #expect(item.context.url?.absoluteString == "https://github.com/acme/app/pull/30817")
        #expect(source.githubDetail(for: item)?.title == "Spaces switcher")
    }

    @Test func theCLIAsksForYourOpenPullRequestsWithTheHoldLabel() {
        #expect(GitHubCLIClient.heldForTrialQuery == "is:pr is:open author:@me label:hold archived:false")
    }
}
