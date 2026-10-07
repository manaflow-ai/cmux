@testable import CmuxNextFeed
import Foundation
import Testing

@MainActor
private final class RecordingGitHubOwner: FeedPostingSource {
    var posted: [FeedItem] = []
    var sink: (@MainActor (FeedSourceEvent) -> Void)?

    func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void) {
        self.sink = sink
        sink(.connection(.connected))
        sink(.snapshot(FeedSnapshot(revision: 0, user: "usr_test", device: "Mac", items: [])))
    }

    func send(_ intent: FeedIntent) {}
    func stop() { sink = nil }

    func post(_ item: FeedItem) {
        if let key = item.dedupeKey, posted.contains(where: { $0.dedupeKey == key && $0.isOpenRequest }) { return }
        posted.append(item)
        sink?(.event(FeedEvent(revision: UInt64(posted.count), change: .items([item]))))
    }
}

private final class StubGitHubAPI: GitHubFeedAPI, @unchecked Sendable {
    var notificationResponses: [GitHubAPIResponse<[GitHubNotification]>]
    var reviewResponses: [GitHubAPIResponse<[GitHubReviewRequest]>]
    private(set) var notificationETags: [String?] = []
    private(set) var reviewETags: [String?] = []

    init(
        notificationResponses: [GitHubAPIResponse<[GitHubNotification]>],
        reviewResponses: [GitHubAPIResponse<[GitHubReviewRequest]>]
    ) {
        self.notificationResponses = notificationResponses
        self.reviewResponses = reviewResponses
    }

    func notifications(etag: String?) async throws -> GitHubAPIResponse<[GitHubNotification]> {
        notificationETags.append(etag)
        return notificationResponses.isEmpty ? GitHubAPIResponse(value: []) : notificationResponses.removeFirst()
    }

    func reviewRequests(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]> {
        reviewETags.append(etag)
        return reviewResponses.isEmpty ? GitHubAPIResponse(value: []) : reviewResponses.removeFirst()
    }
}

@Suite
@MainActor
struct GitHubFeedSourceTests {
    private let now = Date(timeIntervalSince1970: 1_791_039_600)

    @Test func supportedNotificationsBecomeNoticesAndReviewRequestsDeduplicate() async {
        let owner = RecordingGitHubOwner()
        let api = StubGitHubAPI(
            notificationResponses: [GitHubAPIResponse(value: [
                Self.notification(id: "1", reason: "assign", title: "Assigned", number: 7),
                Self.notification(id: "2", reason: "mention", title: "Mentioned", number: 8),
                Self.notification(id: "3", reason: "ci_activity", title: "Checks", number: 9),
                Self.notification(id: "4", reason: "comment", title: "Ignored", number: 10),
                Self.notification(id: "5", reason: "review_requested", title: "Review", number: 11),
            ])],
            reviewResponses: [GitHubAPIResponse(value: [Self.review(number: 11)])]
        )
        let source = GitHubFeedSource(owner: owner, client: api, now: { self.now })
        await source.refresh()

        #expect(owner.posted.count == 4)
        #expect(owner.posted.filter { $0.kind == "review" }.count == 1)
        #expect(owner.posted.filter { $0.priority == .high }.count == 1)
        #expect(source.githubDetails.count == 4)
        #expect(source.githubDetails.values.first { $0.number == 11 }?.body == "PR body")
    }

    @Test func refreshUsesEtagsAndDoesNotPostNotModifiedResponses() async {
        let owner = RecordingGitHubOwner()
        let api = StubGitHubAPI(
            notificationResponses: [
                GitHubAPIResponse(value: [Self.notification(id: "1", reason: "mention", title: "Mentioned", number: 8)], etag: "n1"),
                GitHubAPIResponse(value: nil, etag: "n1", notModified: true),
            ],
            reviewResponses: [
                GitHubAPIResponse(value: [], etag: "r1"),
                GitHubAPIResponse(value: nil, etag: "r1", notModified: true),
            ]
        )
        let source = GitHubFeedSource(owner: owner, client: api, now: { self.now })
        await source.refresh()
        await source.refresh()

        #expect(owner.posted.count == 1)
        #expect(api.notificationETags == [nil, "n1"])
        #expect(api.reviewETags == [nil, "r1"])
    }

    @Test func issueSearchPayloadWithoutRepositoryUsesRepositoryURL() throws {
        let json = """
        {"id":1,"number":42,"title":"Fix","html_url":"https://github.com/acme/tool/pull/42","repository_url":"https://api.github.com/repos/acme/tool","body":"PR body","state":"open","updated_at":"2026-10-03T00:00:00Z","pull_request":{"head":{"ref":"feature/fix"}}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let review = try decoder.decode(GitHubReviewRequest.self, from: Data(json.utf8))
        #expect(review.repository.fullName == "acme/tool")
        #expect(review.branch == "feature/fix")
    }

    @Test func detailLookupUsesDedupeWhenOwnerAssignsAnotherID() async {
        let owner = RecordingGitHubOwner()
        let api = StubGitHubAPI(
            notificationResponses: [GitHubAPIResponse(value: [])],
            reviewResponses: [GitHubAPIResponse(value: [Self.review(number: 42)])]
        )
        let source = GitHubFeedSource(owner: owner, client: api, now: { self.now })
        await source.refresh()
        let ownerItem = FeedItem(
            id: "fi_owner_assigned", title: FeedStrings.github,
            prompt: .review(.init(subject: .pr, ref: "https://github.com/acme/tool/pull/42")),
            dedupeKey: "github:review:acme/tool:42", poster: FeedPoster(kind: .integration, label: "GitHub"),
            createdAt: self.now
        )
        #expect(source.githubDetail(for: ownerItem)?.title == "Review")
    }

    @Test func localAdapterPostsAndTriagesThroughTheSameOwner() async {
        let primary = MockFeedSource(snapshot: FeedSnapshot(revision: 0, user: "usr_test", device: "Mac", items: []))
        let adapter = LocalFeedSourceAdapter(primary: primary)
        let model = FeedModel(source: adapter, clock: { self.now })
        model.start()
        let item = FeedItem(
            id: "fi_github", title: FeedStrings.github, body: "acme/tool#42",
            prompt: .notice, dedupeKey: "github:notification:42",
            poster: FeedPoster(kind: .integration, label: "GitHub"), createdAt: self.now
        )
        adapter.post(item)
        #expect(model.item("fi_github") == item)
        model.archive([item.id])
        await Task.yield()
        #expect(model.item(item.id)?.archivedAt == self.now)
    }

    private static func notification(id: String, reason: String, title: String, number: Int) -> GitHubNotification {
        GitHubNotification(
            id: id, reason: reason,
            subject: .init(title: title, url: "https://api.github.com/repos/acme/tool/issues/\(number)", type: "PullRequest"),
            repository: .init(fullName: "acme/tool", htmlURL: "https://github.com/acme/tool"),
            updatedAt: Date(timeIntervalSince1970: 1_791_039_500)
        )
    }

    private static func review(number: Int) -> GitHubReviewRequest {
        GitHubReviewRequest(
            id: number, number: number, title: "Review", htmlURL: "https://github.com/acme/tool/pull/\(number)",
            repository: .init(fullName: "acme/tool", htmlURL: "https://github.com/acme/tool"),
            body: "PR body", state: "open", branch: "feature/review", updatedAt: Date(timeIntervalSince1970: 1_791_039_500)
        )
    }
}
