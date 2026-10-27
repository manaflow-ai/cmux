import CryptoKit
public import Foundation
public import CmuxNextWakeups

/// Polls GitHub and posts integration items into the existing local feed owner.
/// ETags and the detail cache are client state; item lifecycle, dedupe, and
/// triage remain owned by the feed owner.
///
/// Each wait is the interval times the Energy Saver's ``EnergyPolicy/pollStretch``. While no cmux
/// window shows (``ShownWindows``) no refresh is booked; a window showing again books the next one
/// an interval after the last, at once when that has passed (p14-energy-032), as Chromium stops a
/// hidden page's timers and runs what came due once it shows (`content/public/browser/visibility.h`).
///
/// The next refresh is a background ``MainDeadline`` aligned on the app's node (``TimerAlignment/whenHidden(_:)``):
/// while the app is hidden or its displays sleep, a booked refresh wakes on a whole uptime second shared with every
/// other hidden wake, as Blink aligns a hidden page's timers (`kDefaultThrottledWakeUpInterval`,
/// third_party/blink/renderer/platform/scheduler/main_thread/page_scheduler_impl.h).
@MainActor
public final class GitHubFeedSource: GitHubFeedDetailProviding {
    public static let defaultInterval: Duration = .seconds(120)
    public static let supportedNotificationReasons: Set<String> = ["assign", "ci_activity", "mention", "review_requested"]

    private let owner: any FeedPostingSource
    private let client: any GitHubFeedAPI
    private var interval: Duration
    /// The app's Energy Saver policy, read at each booking.
    private let energy: EnergyPolicySource
    /// Whether a cmux window shows; nil polls whether or not one does.
    private let shown: ShownWindows?
    private var shownObservation: ShownWindowsObservation?
    /// Between ``start()`` and ``stop()``: the poll runs, or waits for a window to show.
    private var polling = false
    /// A refresh of the poll runs now; it books the next one itself when it ends.
    private var pollRefreshing = false
    /// When the last poll refresh of this generation ended, in the deadline scheduler's uptime; nil
    /// before its first, so a start while hidden refreshes on the first show.
    private var lastRefreshEnded: Duration?
    private let now: @MainActor () -> Date
    /// The poll's running refresh, which ``stop()`` cancels (that ends its `gh` child). Set from
    /// ``start()`` until ``stop()``; tests read it to await a refresh they stopped.
    private(set) var runner: Task<Void, Never>?
    /// The next refresh, one deadline at a time: set after each refresh finishes.
    let nextRefresh: MainDeadline
    /// The app's one deadline scheduler: its uptime times the interval since the last refresh.
    private let deadlines: MainDeadlineScheduler
    /// Bumped by every start and stop: a refresh of an older generation posts, stores and
    /// schedules nothing (``stop()`` may land while its `gh` call runs).
    private var pollGeneration = 0
    /// The generation whose refresh runs now; a stopped one never blocks the next start's.
    private var refreshing: Int?
    private var notificationETag: String?
    private var reviewETag: String?
    private var checksETag: String?
    private(set) public var lastError: String?
    public private(set) var githubDetails: [String: GitHubFeedDetail] = [:]

    /// - Parameters:
    ///   - deadlines: The app's one deadline scheduler (`AppServices.mainDeadlines`): the next refresh is a
    ///     background deadline on it.
    ///   - appNode: The app's visibility node (`AppVisibilitySource.node`): the next refresh is aligned on it while
    ///     the app is hidden; nil keeps it flexible.
    public init(
        owner: any FeedPostingSource,
        client: any GitHubFeedAPI = GitHubCLIClient(),
        interval: Duration = GitHubFeedSource.defaultInterval,
        energy: EnergyPolicySource,
        shown: ShownWindows?,
        deadlines: MainDeadlineScheduler,
        appNode: VisibilityNode?,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.owner = owner
        self.client = client
        self.interval = interval
        self.energy = energy
        self.shown = shown
        self.now = now
        self.deadlines = deadlines
        nextRefresh = MainDeadline(owner: Self.refreshOwner, workClass: .background,
                                   alignment: appNode.map(TimerAlignment.whenHidden) ?? .flexible, scheduler: deadlines)
        shownObservation = shown?.observe { [weak self] anyShown in self?.shownChanged(anyShown) }
    }

    /// The next refresh's owner in the board and the wakeup ledger.
    static let refreshOwner = "GitHubFeedSource.refresh"

    /// The wait between two refreshes now: the interval stretched by the Energy Saver.
    var currentInterval: Duration { interval * energy.policy.pollStretch }

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

    /// Starts the poll: a refresh now while a window shows, else once one shows.
    public func start() {
        stop()
        polling = true
        if isShown { beginRefresh(pollGeneration) }
    }

    public func stop() {
        polling = false
        pollRefreshing = false
        pollGeneration += 1
        lastRefreshEnded = nil
        runner?.cancel()
        runner = nil
        nextRefresh.cancel()
    }

    /// Whether a window shows (always, with no ``ShownWindows``).
    private var isShown: Bool { shown?.anyShown ?? true }

    /// The last window went away: the booked refresh goes (a running one books none). A window
    /// showing again books the next one an interval after the last, at once when that has passed.
    private func shownChanged(_ anyShown: Bool) {
        guard polling, !pollRefreshing else { return }
        guard anyShown else { return nextRefresh.cancel() }
        let generation = pollGeneration
        let wait = currentInterval - (lastRefreshEnded.map { deadlines.uptime - $0 } ?? currentInterval)
        guard wait > .zero else { return beginRefresh(generation) }
        nextRefresh.schedule(after: wait) { [weak self] in self?.beginRefresh(generation) }
    }

    /// Runs one refresh of the poll `generation` in ``runner``, so ``stop()`` cancels it, and
    /// arms the next one ``currentInterval`` after it ends while a window shows (Chromium's
    /// self-reposting delayed task).
    private func beginRefresh(_ generation: Int) {
        guard generation == pollGeneration else { return }
        pollRefreshing = true
        // task-owner: `runner`; one poll refresh; stop() cancels it (that ends its `gh` child)
        // main-hop-allow: refresh is the source's main-actor poll (its awaits are the `gh` calls); its posts and ETags apply in order on the feed owner
        runner = Task { @MainActor [weak self] in
            guard let self else { return }
            await refresh()
            guard generation == pollGeneration else { return }
            pollRefreshing = false
            lastRefreshEnded = deadlines.uptime
            guard isShown else { return }
            // wakeup-allow: periodic GitHubFeedSource.refresh (GitHub has no push for the feed; stretched by the saver, none while no window shows, aligned while the app is hidden; task 066b moves it to NSBackgroundActivityScheduler)
            nextRefresh.schedule(after: currentInterval) { [weak self] in self?.beginRefresh(generation) }
        }
    }

    /// Clears client-only detail when the signed-in account changes.
    public func resetDetails() {
        resetConditionalRequests()
    }

    /// Changes the polling cadence. A running source restarts its cancellable
    /// loop so the new interval is observed immediately.
    public func setInterval(_ interval: Duration) {
        self.interval = interval
        if polling { start() }
    }

    /// Refreshes immediately while retaining the conditional request ETags.
    /// A refresh that ``stop()`` overtakes drops what its calls return.
    public func refresh() async {
        let generation = pollGeneration
        guard refreshing != generation else { return }
        refreshing = generation
        defer { if refreshing == generation { refreshing = nil } }
        do {
            let notifications = try await client.notifications(etag: notificationETag)
            guard generation == pollGeneration else { return }
            notificationETag = notifications.etag ?? notificationETag
            if let value = notifications.value, !notifications.notModified {
                for notification in value where Self.supportedNotificationReasons.contains(notification.reason) {
                    let (item, detail) = makeItem(from: notification)
                    post(item, detail: detail)
                }
            }
            let reviews = try await client.reviewRequests(etag: reviewETag)
            guard generation == pollGeneration else { return }
            reviewETag = reviews.etag ?? reviewETag
            if let value = reviews.value, !reviews.notModified {
                for review in value {
                    let (item, detail) = makeItem(from: review)
                    post(item, detail: detail)
                }
            }
            let checks = try await client.failingChecks(etag: checksETag)
            guard generation == pollGeneration else { return }
            checksETag = checks.etag ?? checksETag
            if let value = checks.value, !checks.notModified {
                for review in value {
                    let (item, detail) = makeCheckItem(from: review)
                    post(item, detail: detail)
                }
            }
            lastError = nil
        } catch {
            if generation == pollGeneration { lastError = String(describing: error) }
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
        let dedupe = (isReview ? number : nil).map { "github:review:\(notification.repository.fullName):\($0)" }
            ?? "github:notification:\(notification.id)"
        let prompt: FeedPrompt = isReview
            ? .review(.init(subject: .pr, ref: url?.absoluteString ?? notification.subject.title))
            : .notice
        let item = FeedItem(
            id: stableID(dedupe), home: .local(install: "github"), title: FeedStrings.github,
            body: notificationReference(repository: notification.repository.fullName, number: number), prompt: prompt,
            priority: notification.reason == "ci_activity" ? .high : .normal, dedupeKey: dedupe,
            thread: "github:\(notification.repository.fullName)", context: FeedContext(url: url),
            expiresAt: now().addingTimeInterval(7 * 24 * 60 * 60), poster: FeedPoster(kind: .integration, label: "GitHub"),
            createdAt: notification.updatedAt, updatedAt: now()
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
            expiresAt: now().addingTimeInterval(7 * 24 * 60 * 60), poster: FeedPoster(kind: .integration, label: "GitHub"),
            createdAt: review.updatedAt, updatedAt: now()
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
            context: FeedContext(url: url), expiresAt: now().addingTimeInterval(7 * 24 * 60 * 60),
            poster: FeedPoster(kind: .integration, label: "GitHub"), createdAt: review.updatedAt, updatedAt: now()
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
