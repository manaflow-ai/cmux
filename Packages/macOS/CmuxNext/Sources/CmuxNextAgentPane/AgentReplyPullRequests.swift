public import Foundation

/// The pull requests reply links and the pull request bars point at, for their cards: each read
/// with gh once, and again only when its answer is stale, so the same link is never read twice in
/// a minute and two readers of one link share one read.
///
/// A card reads the cache (``answer(_:)``) and never waits for gh, so hovering a link is never a
/// call to GitHub; the links a page shows are registered when it inspects them
/// (``register(_:)``), which is once per host request — the page gathers every reply's links
/// into one — not once per reply and never once per hover. A read that fails — no gh, no
/// network, a rate limit — leaves the last good answer and its age in place, and is not tried
/// again for `retry`, so a rate-limited GitHub never replaces the pull request with an error.
///
/// Every read uses the user's own GitHub quota (Leo 2026-11-07: "I assume this goes from what the
/// individual user pulls, and so that uses their GitHub quota... batch it ... using it at a good
/// pace so to not starve it"), so it is spent with care:
/// - An answer's freshness follows its state: an open pull request is fresh a minute, a merged or
///   closed one ``settledFreshness`` (``stale(_:)``).
/// - A stale link the cache has an answer for is probed first, with every other stale link a page
///   asked for lately, in one batched call (``AgentChatPullRequestReader/probe(_:checks:)``); only
///   the ones that changed take the full read (``changed(_:_:)``).
/// - Every GraphQL read reports the rate limit it left, and under ``Budget``'s floors the cache
///   stops prefetching, then stops reading, until the limit resets.
@MainActor
public final class AgentReplyPullRequests {
    private struct Entry {
        /// The last answer gh gave; nil until it gives one.
        var pullRequest: AgentPanePullRequest?
        /// When it gave that answer, or when a probe last found it unchanged.
        var at: Date?
        /// When the read that gave that answer (or the probe that confirmed it) began.
        var readFrom: Date?
        /// The last read of this link, good or not; nil until one finishes.
        var tried: ContinuousClock.Instant?
        /// The newest of `at` and `tried`, for dropping the stalest link.
        var touched: ContinuousClock.Instant
        /// When a page last registered this link or a card asked for it, for riding along in a
        /// probe (``interest``).
        var asked: ContinuousClock.Instant?
    }

    /// The clock the cache reads, injectable so a test runs half an hour in a moment.
    struct Now {
        var instant: @MainActor () -> ContinuousClock.Instant = { .now }
        var date: @MainActor () -> Date = { Date() }
    }

    /// The rules a read follows. ``legacy`` is the cache as it was before the quota work, kept only
    /// so the measurement test can count what those rules cost against the same scenario: one
    /// freshness for every state, no probe, no ride-along, no rate budget.
    enum Rules {
        case current
        case legacy
    }

    /// The last rate limit GitHub reported, and what it allows.
    ///
    /// The GraphQL limit is points per hour (5,000 for a user), shared with everything else the
    /// user runs against GitHub: their own `gh`, scripts, agents. The cache is a background reader
    /// and must give way first. Under ``softFloor(_:)`` (a tenth of the limit, at least 500 points)
    /// it stops prefetching (``register(_:)`` and the ride-along of a probe), so only a card the
    /// person opens reads, and at most once per its freshness. Under ``hardFloor`` it reads nothing
    /// and serves its cache until `resetAt`, leaving the last points to the user's own work. A
    /// limit past its `resetAt` says nothing: the points have refilled.
    nonisolated struct Budget: Equatable, Sendable {
        static let hardFloor = 100

        var last: AgentChatPullRequestReader.RateLimit?

        static func softFloor(_ limit: Int) -> Int { max(limit / 10, 500) }

        /// Whether a read may run at `date`: a `background` one (a prefetch), or a card's own.
        func allows(background: Bool, at date: Date) -> Bool {
            guard let last, date < last.resetAt else { return true }
            if last.remaining < Self.hardFloor { return false }
            return !background || last.remaining >= Self.softFloor(last.limit)
        }
    }

    /// The App's one cache: every chat's cards read through it.
    public static let shared = AgentReplyPullRequests()
    /// The most links kept; the stalest goes first.
    static let maximumKept = 200
    /// The most links one ``register(_:)`` prefetches, so a transcript full of pull requests cannot
    /// start a hundred reads at once.
    ///
    /// It is a whole host request, because that is what the page sends: it gathers its chips' links
    /// across every reply and asks for them in one `link.inspect`
    /// (``AgentPaneReplyRequest/maximumInspect``). A smaller number was a bound on the page rather
    /// than on the reply — the links past it were read when a card opened them, one read each,
    /// which is the per-card call this cache exists to avoid. Covering the request instead costs
    /// one more batched read (64 links at ``AgentChatPullRequestReader/batchSize`` 50 is two): two
    /// calls to GitHub for a page full of pull requests, against up to forty-eight.
    static let maximumRegistered = AgentPaneReplyRequest.maximumInspect
    /// How long a merged or closed pull request's answer stays fresh: an hour. What the card shows
    /// of one (title, state, lines, labels, checks) rarely changes after it settles, and when it
    /// does (a reopen, a late label) an hour-old card is the cost; an open one stays at a minute
    /// because its checks, review and mergeability move while people watch it.
    static let settledFreshness: Duration = .seconds(3600)
    /// How long after a page or a card last asked for a link it rides along in another link's
    /// probe: the links of a chat someone is looking at, not every link the cache still holds.
    static let interest: Duration = .seconds(300)

    private let reader: AgentChatPullRequestReader
    private let freshness: Duration
    private let retry: Duration
    private let settled: Duration
    private let rules: Rules
    private let now: Now
    let avatars: AgentReplyAvatars
    /// What the last GraphQL read said of the rate limit.
    private(set) var budget = Budget()
    private var entries: [URL: Entry] = [:]
    private var inflight: [URL: Task<Void, Never>] = [:]
    /// This Mac's chat folders by the GitHub repository their `origin` names (lowercased
    /// `owner/name`), most recent first: where a pull request's commits may already be, so its diff
    /// is read from them before GitHub (``folders(of:)``).
    private var folders: [String: [String]] = [:]
    /// The most folders kept per repository, and repositories kept.
    static let maximumFolders = 8
    static let maximumRepositories = 32

    public convenience init(reader: AgentChatPullRequestReader = AgentChatPullRequestReader(),
                            freshness: Duration = .seconds(60), retry: Duration = .seconds(300)) {
        self.init(reader: reader, freshness: freshness, retry: retry, settled: Self.settledFreshness)
    }

    init(reader: AgentChatPullRequestReader, freshness: Duration = .seconds(60), retry: Duration = .seconds(300),
         settled: Duration, rules: Rules = .current, now: Now = Now(), avatars: AgentReplyAvatars = AgentReplyAvatars()) {
        self.reader = reader
        self.freshness = freshness
        self.retry = retry
        self.settled = rules == .legacy ? freshness : settled
        self.rules = rules
        self.now = now
        self.avatars = avatars
    }

    /// What the cache has for `url`, with its author's avatar when that is held, and a background
    /// read when it is stale unless `read` is false (a page asking for many links it registered,
    /// whose reads the registration batches). Never waits.
    public func answer(_ url: URL, read: Bool = true) -> AgentPanePullRequestAnswer {
        if read {
            entries[url]?.asked = now.instant()
            _ = startRead(url)
        }
        let entry = entries[url]
        var pullRequest = entry?.pullRequest
        var avatarLoading = false
        if let held = pullRequest {
            pullRequest?.authorAvatar = avatars.image(login: held.author, address: held.authorAvatarURL)
            avatarLoading = avatars.loading(held.author)
        }
        // An avatar still loading counts as reading, so an open card keeps asking until it arrives.
        return AgentPanePullRequestAnswer(pullRequest: pullRequest,
                                          fetchedAt: entry?.at?.timeIntervalSince1970,
                                          readFrom: entry?.readFrom?.timeIntervalSince1970,
                                          reading: inflight[url] != nil || avatarLoading)
    }

    /// Keeps the pull requests a reply links fresh, so a card has them before the pointer arrives:
    /// batched reads for the whole request (``AgentChatPullRequestReader/read(urls:)``, one
    /// `gh api graphql` per ``AgentChatPullRequestReader/batchSize``), never one read per link. A
    /// page that mentions fifty pull requests is one call to GitHub, which is the point: the card
    /// Leo saw said "GitHub rate limit" because every link cost its own. A prefetch, so it waits
    /// while the rate limit is under its soft floor (``Budget``).
    public func register(_ urls: [URL]) {
        let urls = Array(urls.prefix(Self.maximumRegistered))
        let instant = now.instant()
        for url in urls { entries[url]?.asked = instant }
        guard rules == .legacy || budget.allows(background: true, at: now.date()) else { return }
        var wanted: [URL] = []
        for url in urls where inflight[url] == nil && stale(url) && !wanted.contains(url) {
            wanted.append(url)
        }
        refresh(wanted)
    }

    /// Reads `url`, waiting for a read already running or starting one. No card takes this path —
    /// every one of them draws from ``answer(_:)`` and never waits — so this is what a caller that
    /// does need the answer in hand (and the tests below) uses.
    public func read(_ url: URL) async -> AgentPanePullRequest? {
        if let task = startRead(url) { await task.value }
        return entries[url]?.pullRequest
    }

    /// Whether `url` is worth reading: never read, or its last read is old enough. An open pull
    /// request is re-read after `freshness`, a merged or closed one after ``settledFreshness``;
    /// one that has never answered waits `retry`, so a rate limit is not met with another call a
    /// minute later.
    private func stale(_ url: URL) -> Bool {
        guard let entry = entries[url], let tried = entry.tried else { return true }
        let wait = entry.pullRequest.map { ["merged", "closed", "not_planned"].contains($0.state) ? settled : freshness } ?? retry
        return now.instant() - tried >= wait
    }

    /// The read running for `url`, a new one when it is stale and the budget allows a card's read,
    /// else nil. Every other stale link a page asked for lately rides along while the budget
    /// allows a prefetch: a probe of fifty costs GitHub what a probe of one does.
    private func startRead(_ url: URL) -> Task<Void, Never>? {
        if let task = inflight[url] { return task }
        guard stale(url) else { return nil }
        guard rules == .current else { return refresh([url]) }
        let date = now.date()
        guard budget.allows(background: false, at: date) else { return nil }
        var wanted = [url]
        if budget.allows(background: true, at: date) {
            let instant = now.instant()
            for (other, entry) in entries where wanted.count < AgentChatPullRequestReader.batchSize && other != url
                && inflight[other] == nil && entry.pullRequest != nil && entry.asked.map({ instant - $0 < Self.interest }) == true
                && stale(other) && AgentChatPullRequestReader.Target(url: other.absoluteString) != nil {
                wanted.append(other)
            }
        }
        return refresh(wanted)
    }

    /// One task that brings `urls` up to date, every one of them in flight on it; nil for none.
    /// Under ``Rules/current``, a link with an answer on github.com is probed first and fully read
    /// only when it changed; the rest are read at once.
    @discardableResult
    private func refresh(_ urls: [URL]) -> Task<Void, Never>? {
        guard !urls.isEmpty else { return nil }
        let reader = reader
        var probed: [URL] = []
        var checks: Set<String> = []
        var full: [URL] = []
        for url in urls {
            guard rules == .current, let held = entries[url]?.pullRequest,
                  AgentChatPullRequestReader.Target(url: url.absoluteString) != nil else {
                full.append(url)
                continue
            }
            probed.append(url)
            if ["open", "draft"].contains(held.state) { checks.insert(url.absoluteString) }
        }
        let toProbe = probed, toCheck = checks, toRead = full
        // task-owner: one refresh for a request's links; a card opened meanwhile shares it.
        let task = Task { [weak self] in
            var fullReads = toRead
            if !toProbe.isEmpty {
                let began = self?.now.date() ?? Date()
                let result = await reader.probe(toProbe.map(\.absoluteString), checks: toCheck)
                guard let self else { return }
                fullReads += self.settle(toProbe, by: result, began: began)
            }
            guard !fullReads.isEmpty, let self else { return }
            let began = self.now.date()
            // The probe may have brought the budget under the floor: the changed links wait for it
            // to refill, counted as tried, instead of spending what is left (review of #37571).
            guard self.budget.allows(background: false, at: began) else {
                self.absorb([:], for: fullReads, began: began)
                return
            }
            let batch = await reader.readBatch(urls: fullReads.map(\.absoluteString))
            self.note(batch.rate)
            self.absorb(batch.answers, for: fullReads, began: began)
        }
        for url in urls { inflight[url] = task }
        return task
    }

    /// What a probe found: a link whose answer still holds is fresh again from now, a link the
    /// probe could not answer counts as tried and keeps its answer, and the links that changed
    /// (or that GitHub answered null for) are returned for the full read.
    private func settle(_ urls: [URL], by result: AgentChatPullRequestReader.ProbeResult, began: Date) -> [URL] {
        note(result.rate)
        var changed: [URL] = []
        for url in urls {
            guard let answer = result.probes[url.absoluteString] else {
                record(nil, for: url, began: began)
                continue
            }
            guard let probe = answer, let held = entries[url]?.pullRequest, !Self.changed(held, probe) else {
                changed.append(url)
                continue
            }
            record(held, for: url, began: began)
        }
        trim()
        return changed
    }

    /// Whether `probe` says `held` is out of date: another `updatedAt` or state, or, for an open
    /// pull request, another head rollup sum (a check finishing moves no `updatedAt`).
    static func changed(_ held: AgentPanePullRequest, _ probe: AgentChatPullRequestReader.Probe) -> Bool {
        if probe.updatedAt != held.updatedAt || probe.state != held.state { return true }
        return ["open", "draft"].contains(held.state)
            && (probe.rollupState != held.rollupState || probe.baseRollupState != held.baseRollupState
                || probe.mergeable != held.mergeable)
    }

    private func note(_ rate: AgentChatPullRequestReader.RateLimit?) {
        if let rate { budget.last = rate }
    }

    /// What a batched read answered. A URL GitHub did not answer for (offline, timed out, rate
    /// limited) keeps its last answer, and every URL of the batch counts as tried, so a failed
    /// batch is not asked again at once.
    private func absorb(_ answers: [String: AgentPanePullRequest?], for urls: [URL], began: Date) {
        for url in urls { record(answers[url.absoluteString] ?? nil, for: url, began: began) }
        trim()
    }

    /// Writes one read's outcome. A read that failed leaves the last good answer and its age
    /// alone: a rate-limited GitHub must not replace the pull request the card is showing. A new
    /// answer starts its author's avatar load, so the image is there when a card opens.
    private func record(_ pullRequest: AgentPanePullRequest?, for url: URL, began: Date) {
        let instant = now.instant()
        var entry = entries[url] ?? Entry(touched: instant)
        entry.tried = instant
        entry.touched = instant
        // Someone asked for every link that is read: a page or a card, before it had an entry.
        entry.asked = entry.asked ?? instant
        if let pullRequest {
            entry.pullRequest = pullRequest
            entry.at = now.date()
            entry.readFrom = began
            _ = avatars.image(login: pullRequest.author, address: pullRequest.authorAvatarURL)
        }
        entries[url] = entry
        inflight[url] = nil
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Puts `pullRequest` in the cache for `url` as a read that just answered (the instant-create
    /// bench's `github_right`: the link card already read it, as in a chat). Fresh for `freshness`.
    public func seed(_ pullRequest: AgentPanePullRequest, for url: URL) {
        record(pullRequest, for: url, began: now.date())
    }
    #endif

    /// Records that `folder`, a chat's folder on this Mac, is a checkout of `repository`
    /// (`owner/name`, as ``AgentPaneGitHubRepository`` reads its `origin`).
    public func noteFolder(_ folder: String, of repository: String) {
        guard folder.hasPrefix("/"), !folder.contains("\0") else { return }
        let key = repository.lowercased()
        folders[key] = Array(([folder] + (folders[key] ?? []).filter { $0 != folder }).prefix(Self.maximumFolders))
        while folders.count > Self.maximumRepositories, let other = folders.keys.first(where: { $0 != key }) { folders[other] = nil }
    }

    /// The chat folders on this Mac that are checkouts of `repository`, most recent first.
    public func folders(of repository: String) -> [String] { folders[repository.lowercased()] ?? [] }

    /// How many links the cache holds, for the test of its bound.
    var kept: Int { entries.count }

    /// Waits until no read runs, for the tests.
    func idle() async {
        while let task = inflight.values.first { await task.value }
    }

    /// Drops the stalest links until at most ``maximumKept`` are kept; one being read stays. Every
    /// one over the bound, not one per call: a batched read records up to ``maximumRegistered`` at
    /// once, so dropping a single link left the cache longer with every such request.
    private func trim() {
        while entries.count > Self.maximumKept,
              let stalest = entries.filter({ inflight[$0.key] == nil }).min(by: { $0.value.touched < $1.value.touched })?.key {
            entries[stalest] = nil
        }
    }
}
