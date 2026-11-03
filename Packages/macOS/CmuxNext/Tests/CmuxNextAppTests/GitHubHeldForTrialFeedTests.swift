import CmuxNextFeed
import Foundation
import Testing

/// Needs you: a pull request the user opened that waits on their own trial (open, authored by
/// them, carrying the `hold` label, e.g. a structural sidebar change held for a dogfood build) is
/// an open request in the Feed, so it sits in the pinned Needs you section until it lands, closes or
/// the hold comes off (it then leaves GitHub's held list and the request closes).
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

    /// A held list GitHub answers each refresh: a fresh 200 with these pulls, a 304, or a failure.
    nonisolated final class HeldGitHub: GitHubFeedAPI, @unchecked Sendable {
        enum Answer { case pulls([GitHubReviewRequest]), notModified, failure }
        var answer: Answer = .pulls([])
        static let pull = GitHubReviewRequest(
            id: 30817, number: 30817, title: "Spaces switcher", htmlURL: "https://github.com/acme/app/pull/30817",
            repository: .init(fullName: "acme/app"), user: .init(login: "me"), state: "open", updatedAt: FakeGitHub.date)
        func notifications(etag: String?) async throws -> GitHubAPIResponse<[GitHubNotification]> { GitHubAPIResponse(value: []) }
        func reviewRequests(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]> { GitHubAPIResponse(value: []) }
        func heldForTrial(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]> {
            switch answer {
            case let .pulls(pulls): return GitHubAPIResponse(value: pulls, etag: "\"\(pulls.count)\"")
            case .notModified: return GitHubAPIResponse(value: nil, etag: etag, notModified: true)
            case .failure: throw URLError(.notConnectedToInternet)
            }
        }
    }

    final class Mirror {
        var items: [String: FeedItem] = [:]
        func item(_ dedupeKey: String) -> FeedItem? { items.values.first { $0.dedupeKey == dedupeKey } }
    }

    /// #33726: a held PR that lands, closes or loses its label leaves GitHub's held list, and its
    /// request closes on the next fresh answer. A 304 or a failed refresh says nothing about it.
    @Test func aHeldPullRequestMissingFromAFreshAnswerIsNoLongerAnOpenRequest() async throws {
        let github = HeldGitHub()
        github.answer = .pulls([HeldGitHub.pull])
        let owner = InMemoryFeedSource(snapshot: FeedSnapshot(revision: 0, user: "me", device: "Mac", items: []))
        let mirror = Mirror()
        owner.start { event in
            guard case let .event(event) = event, case let .items(items) = event.change else { return }
            for item in items { mirror.items[item.id] = item }
        }
        let source = GitHubFeedSource(owner: owner, client: github, now: { FakeGitHub.date })
        let key = "github:held:acme/app:30817"
        await source.refresh()
        #expect(mirror.item(key)?.isOpenRequest == true)

        github.answer = .notModified
        await source.refresh()
        #expect(mirror.item(key)?.isOpenRequest == true)

        github.answer = .failure
        await source.refresh()
        #expect(mirror.item(key)?.isOpenRequest == true)

        github.answer = .pulls([])
        await source.refresh()
        let closed = try #require(mirror.item(key))
        #expect(!closed.isOpenRequest)
        #expect(closed.cancel?.reason == .poster)

        // The hold goes back on: the PR is a Needs you request again.
        github.answer = .pulls([HeldGitHub.pull])
        await source.refresh()
        #expect(mirror.item(key)?.isOpenRequest == true)
    }

    @Test func theCLIAsksForYourOpenPullRequestsWithTheHoldLabel() {
        #expect(GitHubCLIClient.heldForTrialQuery == "is:pr is:open author:@me label:hold archived:false")
    }
}
