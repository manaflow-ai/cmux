import CryptoKit
public import Foundation
public import CmuxNextWakeups

/// Polls GitHub and posts integration items into the existing local feed owner.
/// ETags and the detail cache are client state; item lifecycle, dedupe, and
/// triage remain owned by the feed owner.
///
/// The poll is a repeating ``BackgroundActivity`` (`NSBackgroundActivityScheduler` in the app): every
/// interval times the Energy Saver's ``EnergyPolicy/pollStretch``, with a quarter of that as tolerance,
/// so macOS batches the wake with others and defers it while the Mac is busy (p14-energy-066b). Each
/// run posts one main-actor intent that starts a refresh. While no cmux window shows
/// (``ShownWindows``) the activity is invalidated; a window showing again schedules it anew and
/// refreshes at once when an interval has passed since the last refresh (p14-energy-032), as
/// Chromium stops a hidden page's timers and runs what came due once it shows
/// (`content/public/browser/visibility.h`).
@MainActor
public final class GitHubFeedSource: GitHubFeedDetailProviding {
    public static let defaultInterval: Duration = .seconds(120)
    public static let supportedNotificationReasons: Set<String> = ["assign", "ci_activity", "mention", "review_requested"]
    /// The poll activity's identifier and owner (an `allowed_periodic` owner of idle-budget.json).
    static let refreshActivity = "com.cmuxterm.next.github-feed.refresh"
    static let refreshOwner = "GitHubFeedSource.refresh"

    private let owner: any FeedPostingSource
    private let client: any GitHubFeedAPI
    private var interval: Duration
    /// The app's Energy Saver policy, read when the poll activity is scheduled.
    private let energy: EnergyPolicySource
    private var energyObservation: MainActorEnergyObservation?
    /// Whether a cmux window shows; nil polls whether or not one does.
    private let shown: ShownWindows?
    private var shownObservation: ShownWindowsObservation?
    /// Schedules the repeating poll activity.
    private let activities: any BackgroundActivityScheduling
    /// The poll activity while it runs, and the interval it was scheduled with.
    private var activity: (activity: any BackgroundActivity, interval: Duration)?
    /// Between ``start()`` and ``stop()``: the poll runs, or waits for a window to show.
    private var polling = false
    /// A refresh of the poll runs now; a run of the activity meanwhile starts none.
    private var pollRefreshing = false
    /// The time since the last poll refresh of this generation ended, on the injected clock; nil
    /// before its first, so a start while hidden refreshes on the first show.
    private var sinceLastRefresh: (@MainActor () -> Duration)?
    /// Starts a stopwatch on the injected clock (opened once, in ``init``, so its instants stay typed).
    private let startStopwatch: @MainActor () -> @MainActor () -> Duration
    private let now: @MainActor () -> Date
    /// The poll's running refresh, which ``stop()`` cancels (that ends its `gh` child). Set from
    /// ``start()`` until ``stop()``; tests read it to await a refresh they stopped.
    private(set) var runner: Task<Void, Never>?
    /// Bumped by every start and stop: a refresh of an older generation posts, stores and
    /// schedules nothing (``stop()`` may land while its `gh` call runs), and an older activity's
    /// intent starts nothing.
    private var pollGeneration = 0
    /// The generation whose refresh runs now; a stopped one never blocks the next start's.
    private var refreshing: Int?
    private var notificationETag: String?
    private var reviewETag: String?
    private var checksETag: String?
    private(set) public var lastError: String?
    public private(set) var githubDetails: [String: GitHubFeedDetail] = [:]

    public init(
        owner: any FeedPostingSource,
        client: any GitHubFeedAPI = GitHubCLIClient(),
        interval: Duration = GitHubFeedSource.defaultInterval,
        energy: EnergyPolicySource,
        shown: ShownWindows?,
        activities: any BackgroundActivityScheduling,
        now: @escaping @MainActor () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.owner = owner
        self.client = client
        self.interval = interval
        self.energy = energy
        self.shown = shown
        self.activities = activities
        self.now = now
        startStopwatch = GitHubFeedSource.stopwatches(on: clock)
        shownObservation = shown?.observe { [weak self] anyShown in self?.shownChanged(anyShown) }
        energyObservation = MainActorEnergyObservation(energy) { [weak self] _ in self?.energyChanged() }
    }

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
        guard isShown else { return }
        scheduleActivity()
        beginRefresh(pollGeneration)
    }

    public func stop() {
        polling = false
        pollRefreshing = false
        pollGeneration += 1
        sinceLastRefresh = nil
        runner?.cancel()
        runner = nil
        invalidateActivity()
    }

    /// Whether a window shows (always, with no ``ShownWindows``).
    private var isShown: Bool { shown?.anyShown ?? true }

    /// The last window went away: the activity goes (a running refresh finishes). A window showing
    /// again schedules it anew and refreshes at once when an interval has passed since the last.
    private func shownChanged(_ anyShown: Bool) {
        guard polling else { return }
        guard anyShown else { return invalidateActivity() }
        scheduleActivity()
        guard (sinceLastRefresh?() ?? currentInterval) >= currentInterval else { return }
        beginRefresh(pollGeneration)
    }

    /// The Energy Saver turned on or off: a running activity is scheduled anew at the new stretch.
    private func energyChanged() {
        guard let activity, activity.interval != currentInterval else { return }
        scheduleActivity()
    }

    /// Schedules the poll activity of this generation at ``currentInterval`` with a quarter of it as
    /// tolerance, in place of the one running.
    private func scheduleActivity() {
        invalidateActivity()
        let interval = currentInterval
        let generation = pollGeneration
        let request = BackgroundActivityRequest(identifier: Self.refreshActivity, owner: Self.refreshOwner,
                                                interval: interval, tolerance: interval / 4)
        let scheduled = activities.schedule(request) { [weak self] in self?.activityRan(generation) }
        activity = (scheduled, interval)
    }

    private func invalidateActivity() {
        activity?.activity.invalidate()
        activity = nil
    }

    /// A run of the activity of `generation` reached the main thread: one refresh, unless the poll
    /// stopped, restarted or went hidden since it was posted, or a refresh already runs.
    private func activityRan(_ generation: Int) {
        guard polling, isShown else { return }
        beginRefresh(generation)
    }

    /// Runs one refresh of the poll `generation` in ``runner``, so ``stop()`` cancels it.
    private func beginRefresh(_ generation: Int) {
        guard generation == pollGeneration, !pollRefreshing else { return }
        pollRefreshing = true
        runner = Task { @MainActor [weak self] in
            guard let self else { return }
            await refresh()
            guard generation == pollGeneration else { return }
            pollRefreshing = false
            sinceLastRefresh = startStopwatch()
        }
    }

    /// Starts stopwatches on `clock`: each call reads the time since that call, later.
    private static func stopwatches<C: Clock<Duration>>(on clock: C) -> @MainActor () -> @MainActor () -> Duration {
        {
            let start = clock.now
            return { start.duration(to: clock.now) }
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
