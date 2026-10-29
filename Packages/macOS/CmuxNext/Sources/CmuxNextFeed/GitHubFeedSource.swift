import CryptoKit
public import Foundation
public import CmuxNextWakeups

/// Polls GitHub and posts integration items into the existing local feed owner.
/// ETags and the detail cache are client state; item lifecycle, dedupe, and
/// triage remain owned by the feed owner.
///
/// The poll is a repeating ``BackgroundActivity`` (`NSBackgroundActivityScheduler` in the app): every
/// interval times the Energy Saver's ``EnergyPolicy/pollStretch``, with a quarter of that as tolerance,
/// so macOS batches the wake with others and defers it while the Mac is busy. Each
/// run posts one main-actor intent that starts a refresh; an intent of an activity replaced since it
/// was posted starts nothing. While no feed surface shows (the ``ShownWindows`` over the nodes of the
/// feed's page tabs, panel and sidebar sections) the activity is invalidated; a surface showing again
/// refreshes an interval after the last refresh, at once when that has passed, and schedules the
/// activity anew then, as Chromium stops a hidden page's timers and runs what came due
/// once it shows (`content/public/browser/visibility.h`).
///
/// No deadline of the poll waits while the app is hidden: the activity is the system's to coalesce (its
/// tolerance), and the catch-up waits only while a feed surface shows, so the Blink-style whole-second
/// alignment of hidden wakes has nothing left to align here.
@MainActor
public final class GitHubFeedSource: GitHubFeedDetailProviding {
    public static let defaultInterval: Duration = .seconds(120)
    public static let supportedNotificationReasons: Set<String> = ["assign", "ci_activity", "mention", "review_requested"]
    /// The owner of the poll activity's runs (an `allowed_periodic` owner of idle-budget.json) and of
    /// the one refresh a show inside the interval waits for.
    static let refreshOwner = "GitHubFeedSource.refresh"

    /// The poll activity's identifier for the app build `bundleID` (nil: the main bundle's): one per
    /// build, as `NSBackgroundActivityScheduler` asks.
    public static func refreshActivityIdentifier(bundleID: String?) -> String {
        "\(bundleID ?? Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.next").github-feed.refresh"
    }

    private let owner: any FeedPostingSource
    private let client: any GitHubFeedAPI
    private var interval: Duration
    /// The app's Energy Saver policy, read when the poll activity is scheduled.
    private let energy: EnergyPolicySource
    private var energyObservation: MainActorEnergyObservation?
    /// Whether a feed surface shows; nil polls whether or not one does.
    private let surfaces: ShownWindows?
    private var surfacesObservation: ShownWindowsObservation?
    /// Schedules the repeating poll activity; each run posts its intent to the main actor.
    private let activities: MainIntentBackgroundActivities
    private let activityIdentifier: String
    /// The poll activity while it runs, the interval it was scheduled with, and its serial: a run's
    /// intent starts a refresh only while the activity that posted it is this one.
    private var activity: (run: any BackgroundActivityRun, interval: Duration, serial: Int)?
    /// Counts the activities scheduled, never reset (a restart's activity gets a new serial too).
    private var activitySerial = 0
    /// After a show inside the interval: the one refresh at the interval's end, which then schedules the activity.
    private let catchUp: MainDeadline
    /// Between ``start()`` and ``stop()``: the poll runs, or waits for a feed surface to show.
    private var polling = false
    /// A refresh of the poll runs now; a run of the activity meanwhile starts none.
    private var pollRefreshing = false
    /// When the last poll refresh of this generation ended, in the deadline scheduler's uptime; nil
    /// before its first, so a start while hidden refreshes on the first show.
    private var lastRefreshEnded: Duration?
    private let now: @MainActor () -> Date
    /// The poll's running refresh, which ``stop()`` cancels (that ends its `gh` child). Set from
    /// ``start()`` until ``stop()``; tests read it to await a refresh they stopped.
    private(set) var runner: Task<Void, Never>?
    /// When the refresh a show inside the interval waits for is due, on the deadlines' uptime; tests read it.
    var catchUpDue: Duration? { catchUp.plannedWake?.due }
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
    ///   - activities: Schedules the repeating poll activity (`.system(work:)` in the app).
    ///   - activityIdentifier: The poll activity's identifier (``refreshActivityIdentifier(bundleID:)``).
    ///   - deadlines: The app's one deadline scheduler (`AppServices.mainDeadlines`): the catch-up is a
    ///     background deadline on it, and its uptime times the interval since the last refresh.
    public init(
        owner: any FeedPostingSource,
        client: any GitHubFeedAPI = GitHubCLIClient(),
        interval: Duration = GitHubFeedSource.defaultInterval,
        energy: EnergyPolicySource,
        surfaces: ShownWindows?,
        activities: MainIntentBackgroundActivities,
        activityIdentifier: String,
        deadlines: MainDeadlineScheduler,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.owner = owner
        self.client = client
        self.interval = interval
        self.energy = energy
        self.surfaces = surfaces
        self.activities = activities
        self.activityIdentifier = activityIdentifier
        self.now = now
        self.deadlines = deadlines
        catchUp = MainDeadline(owner: Self.refreshOwner, workClass: .background, scheduler: deadlines)
        surfacesObservation = surfaces?.observe { [weak self] anyShown in self?.shownChanged(anyShown) }
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

    /// Starts the poll: a refresh now while a feed surface shows, else once one shows.
    public func start() {
        stop()
        polling = true
        resume(pollGeneration)
    }

    public func stop() {
        polling = false
        pollRefreshing = false
        pollGeneration += 1
        lastRefreshEnded = nil
        runner?.cancel()
        runner = nil
        pause()
    }

    /// Whether a feed surface shows (always, with no ``ShownWindows``).
    private var isShown: Bool { surfaces?.anyShown ?? true }

    /// The last feed surface went away: the activity and a waiting catch-up go (a running refresh
    /// finishes). A surface showing again refreshes an interval after the last refresh, at once when
    /// that has passed, and schedules the activity then; while a refresh runs it only schedules it.
    private func shownChanged(_ anyShown: Bool) {
        guard polling else { return }
        guard anyShown else { return pause() }
        guard activity == nil, !catchUp.isScheduled else { return }
        let generation = pollGeneration
        let sinceLast = lastRefreshEnded.map { deadlines.uptime - $0 } ?? currentInterval
        let rest: Duration = pollRefreshing ? .zero : currentInterval - sinceLast
        guard rest > .zero else { return resume(generation) }
        catchUp.schedule(after: rest) { [weak self] in self?.resume(generation) }
    }

    /// A show of the poll `generation`, or the end of the interval it came inside: the activity is
    /// scheduled and one refresh starts, unless one runs.
    private func resume(_ generation: Int) {
        guard generation == pollGeneration, polling, isShown else { return }
        scheduleActivity()
        beginRefresh(generation)
    }

    /// Nothing of the poll stays scheduled: the activity and the catch-up go.
    private func pause() {
        catchUp.cancel()
        invalidateActivity()
    }

    /// The Energy Saver turned on or off: a running activity is scheduled anew at the new stretch, and
    /// a waiting catch-up is booked again for the rest of the new interval.
    private func energyChanged() {
        if catchUp.isScheduled {
            catchUp.cancel()
            return shownChanged(isShown)
        }
        guard let activity, activity.interval != currentInterval else { return }
        scheduleActivity()
    }

    /// Schedules the poll activity at ``currentInterval`` with a quarter of it as tolerance, in place
    /// of the one running, under a new serial.
    private func scheduleActivity() {
        invalidateActivity()
        let interval = currentInterval
        activitySerial += 1
        let serial = activitySerial
        let spec = BackgroundActivity(identifier: activityIdentifier, owner: Self.refreshOwner,
                                      interval: interval, tolerance: interval / 4)
        let run = activities.schedule(spec) { [weak self] in self?.activityRan(serial) }
        activity = (run, interval, serial)
    }

    private func invalidateActivity() {
        activity?.run.invalidate()
        activity = nil
    }

    /// A run of the activity `serial` reached the main thread: one refresh while that activity is
    /// still the scheduled one. A stop, a hide (also one followed by a show) or a reschedule since it
    /// was posted replaced or invalidated it, so it starts nothing; nor does it while a refresh runs.
    private func activityRan(_ serial: Int) {
        guard polling, isShown, activity?.serial == serial else { return }
        beginRefresh(pollGeneration)
    }

    /// Runs one refresh of the poll `generation` in ``runner``, so ``stop()`` cancels it.
    private func beginRefresh(_ generation: Int) {
        guard generation == pollGeneration, !pollRefreshing else { return }
        pollRefreshing = true
        // task-owner: `runner`; one poll refresh; stop() cancels it (that ends its `gh` child)
        // main-hop-allow: refresh is the source's main-actor poll (its awaits are the `gh` calls); its posts and ETags apply in order on the feed owner
        runner = Task { @MainActor [weak self] in
            guard let self else { return }
            await refresh()
            guard generation == pollGeneration else { return }
            pollRefreshing = false
            lastRefreshEnded = deadlines.uptime
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
