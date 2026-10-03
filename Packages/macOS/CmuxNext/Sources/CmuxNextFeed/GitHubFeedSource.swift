import CryptoKit
import Foundation

/// Polls GitHub and posts integration items into the existing local feed owner.
/// ETags and the detail cache are client state; item lifecycle, dedupe, and
/// triage remain owned by the feed owner.
@MainActor
public final class GitHubFeedSource: GitHubFeedDetailProviding {
    public static let defaultInterval: Duration = .seconds(120)
    public static let supportedNotificationReasons: Set<String> = ["assign", "ci_activity", "mention", "review_requested"]

    private let owner: any FeedPostingSource
    private let client: any GitHubFeedAPI
    private var interval: Duration
    private let now: @MainActor () -> Date
    private var runner: Task<Void, Never>?
    private var isRefreshing = false
    private var notificationETag: String?
    private var reviewETag: String?
    private var checksETag: String?
    private(set) public var lastError: String?
    public private(set) var githubDetails: [String: GitHubFeedDetail] = [:]

    public init(
        owner: any FeedPostingSource,
        client: any GitHubFeedAPI = GitHubCLIClient(),
        interval: Duration = GitHubFeedSource.defaultInterval,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.owner = owner
        self.client = client
        self.interval = interval
        self.now = now
    }

    /// Looks up a detail by a provisional or owner-assigned feed id.
    public func githubDetail(for id: String) -> GitHubFeedDetail? { githubDetails[id] }

    /// Drops conditional validators when the authenticated owner changes.
    public func resetConditionalRequests() {
        notificationETag = nil
        reviewETag = nil
        checksETag = nil
        githubDetails.removeAll()
    }

    public func githubDetail(for item: FeedItem) -> GitHubFeedDetail? {
        if let dedupeKey = item.dedupeKey, let detail = githubDetails[dedupeKey] { return detail }
        return githubDetails[item.id]
    }

    public func start() {
        stop()
        runner = Task { @MainActor [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await refresh()
            }
        }
    }

    public func stop() {
        runner?.cancel()
        runner = nil
    }

    /// Clears client-only detail when the signed-in account changes.
    public func resetDetails() {
        resetConditionalRequests()
    }

    /// Changes the polling cadence. A running source restarts its cancellable
    /// loop so the new interval is observed immediately.
    public func setInterval(_ interval: Duration) {
        self.interval = interval
        if runner != nil { start() }
    }

    /// Refreshes immediately while retaining the conditional request ETags.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let notifications = try await client.notifications(etag: notificationETag)
            notificationETag = notifications.etag ?? notificationETag
            if let value = notifications.value, !notifications.notModified {
                for notification in value where Self.supportedNotificationReasons.contains(notification.reason) {
                    let (item, detail) = makeItem(from: notification)
                    post(item, detail: detail)
                }
            }
            let reviews = try await client.reviewRequests(etag: reviewETag)
            reviewETag = reviews.etag ?? reviewETag
            if let value = reviews.value, !reviews.notModified {
                for review in value {
                    let (item, detail) = makeItem(from: review)
                    post(item, detail: detail)
                }
            }
            let checks = try await client.failingChecks(etag: checksETag)
            checksETag = checks.etag ?? checksETag
            if let value = checks.value, !checks.notModified {
                for review in value {
                    let (item, detail) = makeCheckItem(from: review)
                    post(item, detail: detail)
                }
            }
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    private func post(_ item: FeedItem, detail: GitHubFeedDetail) {
        githubDetails[item.dedupeKey ?? item.id] = detail
        owner.post(item)
    }

    private func makeItem(from notification: GitHubNotification) -> (FeedItem, GitHubFeedDetail) {
        let url = notificationURL(repository: notification.repository, subject: notification.subject)
        let isReview = notification.reason == "review_requested"
        let number = githubNumber(from: notification.subject.url)
        let dedupe = isReview && number != nil
            ? "github:review:\(notification.repository.fullName):\(number!)"
            : "github:notification:\(notification.id)"
        let prompt: FeedPrompt = isReview
            ? .review(.init(subject: .pr, ref: url?.absoluteString ?? notification.subject.title))
            : .notice
        let item = FeedItem(
            id: stableID(dedupe), home: .local(install: "github"), title: FeedStrings.github,
            body: notificationReference(repository: notification.repository.fullName, number: number), prompt: prompt,
            priority: notification.reason == "ci_activity" ? .high : .normal, dedupeKey: dedupe,
            thread: "github:\(notification.repository.fullName)", context: FeedContext(url: url),
            poster: FeedPoster(kind: .integration, label: "GitHub"),
            expiresAt: now().addingTimeInterval(7 * 24 * 60 * 60), createdAt: notification.updatedAt, updatedAt: now()
        )
        let detail = GitHubFeedDetail(
            repository: notification.repository.fullName, number: number, url: url,
            title: notification.subject.title, state: "open", updatedAt: notification.updatedAt
        )
        return (item, detail)
    }

    private func makeItem(from review: GitHubReviewRequest) -> (FeedItem, GitHubFeedDetail) {
        let url = URL(string: review.htmlURL)
        let dedupe = "github:review:\(review.repository.fullName):\(review.number)"
        let item = FeedItem(
            id: stableID(dedupe), home: .local(install: "github"), title: FeedStrings.github,
            body: notificationReference(repository: review.repository.fullName, number: review.number),
            prompt: .review(.init(subject: .pr, ref: review.htmlURL)), priority: .normal, dedupeKey: dedupe,
            thread: "github:\(review.repository.fullName):pr:\(review.number)", context: FeedContext(url: url),
            poster: FeedPoster(kind: .integration, label: "GitHub"),
            expiresAt: now().addingTimeInterval(7 * 24 * 60 * 60), createdAt: review.updatedAt, updatedAt: now()
        )
        let detail = GitHubFeedDetail(
            repository: review.repository.fullName, number: review.number, url: url,
            title: review.title, body: review.body, state: review.state, branch: review.branch, updatedAt: review.updatedAt
        )
        return (item, detail)
    }

    private func makeCheckItem(from review: GitHubReviewRequest) -> (FeedItem, GitHubFeedDetail) {
        let url = URL(string: review.htmlURL)
        let dedupe = "github:checks:\(review.repository.fullName):\(review.number)"
        let item = FeedItem(
            id: stableID(dedupe), home: .local(install: "github"), title: FeedStrings.github,
            body: notificationReference(repository: review.repository.fullName, number: review.number), prompt: .notice, priority: .high,
            dedupeKey: dedupe, thread: "github:\(review.repository.fullName):pr:\(review.number)",
            context: FeedContext(url: url), poster: FeedPoster(kind: .integration, label: "GitHub"),
            expiresAt: now().addingTimeInterval(7 * 24 * 60 * 60), createdAt: review.updatedAt, updatedAt: now()
        )
        let detail = GitHubFeedDetail(
            repository: review.repository.fullName, number: review.number, url: url,
            title: review.title, body: review.body, state: review.state, branch: review.branch,
            checks: [GitHubCheck(name: "GitHub checks", conclusion: "failure", url: url)], updatedAt: review.updatedAt
        )
        return (item, detail)
    }

    private func notificationURL(repository: GitHubNotification.Repository, subject: GitHubNotification.Subject) -> URL? {
        guard let raw = subject.url else { return URL(string: repository.htmlURL ?? "") }
        guard let number = githubNumber(from: raw), let base = repository.htmlURL else { return URL(string: raw) }
        let kind = subject.type?.lowercased().contains("pull") == true ? "pull" : "issues"
        return URL(string: "\(base.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(kind)/\(number)")
    }

    private func githubNumber(from value: String?) -> Int? {
        guard let value, let last = value.split(separator: "/").last else { return nil }
        return Int(last)
    }

    /// The owner keeps only stable provider identifiers. PR and issue text is
    /// retained in `githubDetails` for the current client session.
    private func notificationReference(repository: String, number: Int?) -> String {
        guard let number else { return repository }
        return "\(repository)#\(number)"
    }

    private func stableID(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return "fi_" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}
