import CmuxNextCompat
public import Foundation
public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Reads the pull request of a folder's branch with the user's GitHub CLI (cx-tcwj):
/// `gh pr view --json` ``AgentPanePullRequest/fields`` in the folder, or one pull request by its
/// link (a hover card's `pr.inspect`). Nil when gh is not installed, there is no such pull
/// request, or gh does not answer in time; it never prompts.
public nonisolated struct AgentChatPullRequestReader: Sendable {
    /// `gh`'s path; nil runs `gh` through `/usr/bin/env`, which finds it on the PATH of gh's
    /// environment (``environment(_:)``: the App's PATH, then the usual install folders) as the
    /// child starts, so nothing checks a file before the read.
    var gh: String?
    var timeout: Duration = .seconds(30)
    /// The App's environment, from which gh gets the user's GitHub settings (``githubVariables``).
    var environment: [String: String] = ProcessInfo.processInfo.environment
    /// Runs gh to its end: in the App its one gh runner, a ``BoundedProcessRunner`` that every reader
    /// shares (two gh at once, the rest in arrival order: each may wait up to `timeout`, and
    /// restoring many chats offline must not start one gh per chat, cx-mb1e0); tests pass a fake.
    var processes: any ProcessRunning

    public init(gh: String? = nil, timeout: Duration = .seconds(30), environment: [String: String] = ProcessInfo.processInfo.environment,
                processes: any ProcessRunning) {
        self.gh = gh
        self.timeout = timeout
        self.environment = environment
        self.processes = processes
    }

    /// Folders an app launched from Finder lacks on its PATH, where gh usually is.
    static let installFolders = ["/opt/homebrew/bin", "/usr/local/bin"]
    /// The user's GitHub settings gh reads from its environment: a token-only or proxied setup has
    /// no chip without them (cx-mb1e0).
    static let githubVariables = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_HOST",
                                  "GH_CONFIG_DIR", "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy"]

    public func read(in folder: String) async -> AgentPanePullRequest? {
        await read(arguments: ["pr", "view", "--json", AgentPanePullRequest.fields], in: folder)
    }

    /// The pull request at `url`, a link ``AgentPaneReplyRequest/pullRequestURL(_:)`` rebuilt, so
    /// gh's argument is never anything but that URL. Runs in the home folder: no repository needed.
    ///
    /// Kept for the shape of that one read, which ``read(urls:)`` falls back to for a link on
    /// another host, and for the test of it. No card takes this path: a card's link is read
    /// through ``read(urls:)`` even when it is the only one, because that read is the only one of
    /// the two that can see the base branch's checks.
    public func read(url: URL) async -> AgentPanePullRequest? {
        await read(arguments: ["pr", "view", url.absoluteString, "--json", AgentPanePullRequest.fields],
                   in: home)
    }

    /// Where a read with no repository runs: gh needs none when the pull request is named by URL.
    private var home: String { environment["HOME"] ?? NSHomeDirectory() }

    /// The pull requests at `urls`, wherever their branches are checked out, by URL. github.com
    /// ones take one `gh api graphql` read per ``batchSize``, never one call per pull request;
    /// another host's (GitHub Enterprise) takes one `gh pr view <url>` each. A URL GitHub answered
    /// for has its pull request, or nil when it has none (gone, or not visible); a URL whose read
    /// failed (offline, timed out, rate limited) is left out, so its last answer stands.
    @concurrent public func read(urls: [String]) async -> [String: AgentPanePullRequest?] {
        var targets: [Target] = []
        var others: [String] = []
        for url in urls {
            if let target = Target(url: url) { targets.append(target) } else if url.hasPrefix("https://") { others.append(url) }
        }
        var answers: [String: AgentPanePullRequest?] = [:]
        for start in stride(from: 0, to: targets.count, by: Self.batchSize) {
            let batch = Array(targets[start..<min(start + Self.batchSize, targets.count)])
            // A missing pull request fails the read but leaves the others' data: read it anyway.
            // github.com explicitly: a GH_HOST the App passes on names the user's Enterprise host.
            let arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=" + Self.query(batch)]
            guard let data = await run(arguments, in: nil, anyExit: true) else { continue }
            answers.merge(Self.pullRequests(fromGraphQL: data, batch)) { $1 }
        }
        // In the home folder, like ``read(url:)``: a link on another host names its pull request,
        // so this needs no repository, and the App's own working folder is nobody's repository.
        for url in others {
            if let pullRequest = await read(arguments: ["pr", "view", url, "--json", AgentPanePullRequest.fields], in: home) {
                answers[url] = pullRequest
            }
        }
        return answers
    }

    /// The most pull requests one GraphQL read asks for.
    static let batchSize = 50

    /// One pull request a GraphQL read asks for.
    struct Target: Equatable {
        var url: String
        var owner: String
        var name: String
        var number: Int

        /// Nil unless `url` is `https://github.com/<owner>/<repo>/pull/<n>` with plain names.
        init?(url: String) {
            let parts = url.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let plain = { (s: String) in !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }
            guard parts.count == 7, parts[0] == "https:", parts[1].isEmpty, parts[2] == "github.com", plain(parts[3]), plain(parts[4]),
                  parts[5] == "pull", let number = Int(parts[6]), number > 0, String(number) == parts[6] else { return nil }
            self.url = url
            owner = parts[3]
            name = parts[4]
            self.number = number
        }
    }

    /// The query for `targets`: `p<i>` is the i-th one's pull request, with the fields `gh pr view`
    /// reads (``AgentPanePullRequest/fields``) and its last commit's check rollup.
    static func query(_ targets: [Target]) -> String {
        // Every field ``AgentPanePullRequest/fields`` reads, so a pull request from here is the
        // same pull request a `gh pr view` of it would be: a card drawn from a batched read must
        // not be missing its branches, labels or files.
        // A rollup's contexts carry the run they came from, and both halves of that are read:
        // ``AgentPanePullRequest/identity(_:)`` matches a head check against a base one by its
        // workflow as well as its name, on both sides, and
        // ``AgentPanePullRequest/latestRuns(_:)`` uses the run id on the base side, because a
        // cancelled run a newer run of the same workflow replaced still sits in this list and
        // reads as a failure. Trimming either field degrades the match to the name alone, which
        // would excuse a red of one workflow with a same-named red of another.
        let contexts = """
            contexts(first: 100) { nodes { __typename \
            ... on CheckRun { name status conclusion detailsUrl \
            checkSuite { workflowRun { databaseId workflow { databaseId name } } } } \
            ... on StatusContext { context state targetUrl } } }
            """
        let fields = """
            url number title state isDraft reviewDecision mergeable createdAt updatedAt mergedAt additions deletions \
            changedFiles baseRefName headRefName author { login } labels(first: \(AgentPanePullRequest.maximumLabels)) \
            { nodes { name } } files(first: 100) { nodes { path additions deletions } } \
            commits(last: 1) { nodes { commit { statusCheckRollup { \(contexts) } } } } \
            baseRef { target { ... on Commit { statusCheckRollup { \(contexts) } } } }
            """
        let aliases = targets.enumerated().map { index, target in
            "p\(index): repository(owner: \"\(target.owner)\", name: \"\(target.name)\") { pullRequest(number: \(target.number)) { ...f } }"
        }
        return "query { \(aliases.joined(separator: " ")) } fragment f on PullRequest { \(fields) }"
    }

    /// Each target's pull request in a GraphQL answer, reshaped as `gh pr view` prints it (the
    /// rollup's contexts as `statusCheckRollup`), by the target's URL: nil for a target GitHub
    /// answered null for (no such pull request, or not visible); a target the answer does not
    /// mention (no `data`), or whose null comes with an error other than NOT_FOUND (SSO, a resource
    /// limit), is left out, so it keeps its last answer.
    static func pullRequests(fromGraphQL data: Data, _ targets: [Target]) -> [String: AgentPanePullRequest?] {
        guard let object = try? JSONSerialization.blockingJSONObject(with: data) as? [String: Any],
              let answers = object["data"] as? [String: Any] else { return [:] }
        let unanswered = Set(((object["errors"] as? [[String: Any]]) ?? []).compactMap { error -> String? in
            guard (error["type"] as? String) != "NOT_FOUND" else { return nil }
            return (error["path"] as? [Any])?.first as? String
        })
        var result: [String: AgentPanePullRequest?] = [:]
        for (index, target) in targets.enumerated() {
            guard let alias = answers["p\(index)"] else { continue }
            guard var view = (alias as? [String: Any])?["pullRequest"] as? [String: Any] else {
                if !unanswered.contains("p\(index)") { result[target.url] = .some(nil) }
                continue
            }
            let commit = ((view["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.last?["commit"] as? [String: Any]
            let contexts = (commit?["statusCheckRollup"] as? [String: Any])?["contexts"] as? [String: Any]
            view["statusCheckRollup"] = contexts?["nodes"] as? [[String: Any]] ?? []
            view["commits"] = nil
            // The base branch's tip, under the name `AgentPanePullRequest` reads it by. The tip is
            // what "also red on base" means: the merge rules measure a base red there, not at this
            // pull request's merge base.
            let baseTarget = (view["baseRef"] as? [String: Any])?["target"] as? [String: Any]
            let baseContexts = (baseTarget?["statusCheckRollup"] as? [String: Any])?["contexts"] as? [String: Any]
            view["baseStatusCheckRollup"] = baseContexts?["nodes"] as? [[String: Any]] ?? []
            view["baseRef"] = nil
            // GraphQL wraps a connection's rows in `nodes`; gh prints them as a plain array.
            for key in ["labels", "files"] {
                view[key] = (view[key] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            }
            guard let reshaped = try? JSONSerialization.data(withJSONObject: view),
                  let pullRequest = AgentPanePullRequest(ghView: reshaped) else { continue }
            result[target.url] = .some(pullRequest)
        }
        return result
    }

    /// `@concurrent`: gh's JSON is parsed off the caller's actor (often main).
    @concurrent private func read(arguments: [String], in folder: String?) async -> AgentPanePullRequest? {
        await run(arguments, in: folder, anyExit: false).flatMap(AgentPanePullRequest.init(ghView:))
    }

    /// gh's output for `arguments`; nil when gh is missing, fails (unless `anyExit`) or does not
    /// answer in time (it gets SIGTERM, then SIGKILL). No thread waits for it. Nobody waits for a
    /// chip's pull request now, so gh runs at bestEffort.
    private func run(_ arguments: [String], in folder: String?, anyExit: Bool) async -> Data? {
        let executable = gh ?? Self.env, command = gh == nil ? ["gh"] + arguments : arguments
        let request = ProcessRequest(URL(fileURLWithPath: executable), command, environment: Self.environment(environment),
                                     directory: folder.map { URL(fileURLWithPath: $0) }, timeout: timeout, priority: .bestEffort)
        let outcome = try? await processes.outcome(of: request)
        // A deadline kill is never an answer, nor env's "no gh".
        guard let outcome, outcome.succeeded || (anyExit && outcome.exited && outcome.status != Self.notFound) else { return nil }
        return outcome.output
    }

    /// Where `/usr/bin/env gh` looks for gh: the App's PATH, then the folders an app launched from
    /// Finder lacks on it (``installFolders``).
    public static func searchPath(_ app: [String: String]) -> String {
        ([app["PATH"] ?? "/usr/bin:/bin"] + installFolders).joined(separator: ":")
    }

    /// Runs `gh` found on its environment's PATH (``gh`` nil).
    static let env = "/usr/bin/env"
    /// `env`'s exit status when it finds no `gh` on that PATH: gh is not installed.
    static let notFound: Int32 = 127

    /// gh's environment: no prompts, the App's PATH and gh's install folders (``searchPath(_:)``), HOME,
    /// and the user's GitHub settings. Run as `/usr/bin/env gh` with it, gh is found on that PATH.
    static func environment(_ app: [String: String]) -> [String: String] {
        var environment = ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GIT_TERMINAL_PROMPT": "0",
                           "PATH": searchPath(app)]
        environment["HOME"] = app["HOME"]
        for key in githubVariables { environment[key] = app[key] }
        return environment
    }
}

/// The pull requests reply links and the pull request bars point at, for their cards: each read
/// with gh once, and again only after `freshness`, so the same link is never read twice in a
/// minute and two readers of one link share one read.
///
/// A card reads the cache (``answer(_:)``) and never waits for gh, so hovering a link is never a
/// call to GitHub; the links a page shows are registered when it inspects them
/// (``register(_:)``), which is once per host request — the page gathers every reply's links
/// into one — not once per reply and never once per hover. A read that fails — no gh, no
/// network, a rate limit — leaves the last good answer and its age in place, and is not tried
/// again for `retry`, so a rate-limited GitHub never replaces the pull request with an error.
///
/// Each read runs off the main actor, and its answers land in the cache as one task on the app's
/// scheduler (Chromium's `PostTaskAndReplyWithResult` onto a typed UI task runner,
/// base/task/task_runner_util.h): `background` for a reply's prefetch, which no card shows yet,
/// `visible` for a link a card asked for.
@MainActor
public final class AgentReplyPullRequests {
    private struct Entry {
        /// The last answer gh gave; nil until it gives one.
        var pullRequest: AgentPanePullRequest?
        /// When it gave that answer.
        var at: Date?
        /// The last read of this link, good or not; nil until one finishes.
        var tried: ContinuousClock.Instant?
        /// The newest of `at` and `tried`, for dropping the stalest link.
        var touched: ContinuousClock.Instant
    }

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

    private let reader: AgentChatPullRequestReader
    private let freshness: Duration
    private let retry: Duration
    private let mainWork: MainWorkScheduler
    /// The owner of the reads' answers, interned once.
    private let owner: MainTaskOwner
    private var entries: [URL: Entry] = [:]
    private var inflight: [URL: Task<Void, Never>] = [:]

    /// The App makes one (`AppServices.replyPullRequests`): every chat's cards and the changelog's
    /// read through it, with the App's one gh reader; `mainWork` is the app's scheduler the answers land on.
    public init(reader: AgentChatPullRequestReader, mainWork: MainWorkScheduler, freshness: Duration = .seconds(60),
                retry: Duration = .seconds(300)) {
        self.reader = reader
        self.mainWork = mainWork
        owner = mainWork.board.owner("AgentReplyPullRequests.read")
        self.freshness = freshness
        self.retry = retry
    }

    /// What the cache has for `url`, and a background read when that is stale. Never waits.
    public func answer(_ url: URL) -> AgentPanePullRequestAnswer {
        _ = startRead(url)
        let entry = entries[url]
        return AgentPanePullRequestAnswer(pullRequest: entry?.pullRequest,
                                          fetchedAt: entry?.at?.timeIntervalSince1970,
                                          reading: inflight[url] != nil)
    }

    /// Keeps the pull requests a reply links fresh, so a card has them before the pointer arrives:
    /// batched reads for the whole request (``AgentChatPullRequestReader/read(urls:)``, one
    /// `gh api graphql` per ``AgentChatPullRequestReader/batchSize``), never one read per link. A
    /// page that mentions fifty pull requests is one call to GitHub, which is the point: the card
    /// Leo saw said "GitHub rate limit" because every link cost its own.
    public func register(_ urls: [URL]) {
        var wanted: [URL] = []
        for url in urls.prefix(Self.maximumRegistered) where inflight[url] == nil && stale(url) && !wanted.contains(url) {
            wanted.append(url)
        }
        guard !wanted.isEmpty else { return }
        let task = fetch(wanted, as: .background)
        for url in wanted { inflight[url] = task }
    }

    /// Reads `url`, waiting for a read already running or starting one. No card takes this path —
    /// every one of them draws from ``answer(_:)`` and never waits — so this is what a caller that
    /// does need the answer in hand (and the tests below) uses.
    public func read(_ url: URL) async -> AgentPanePullRequest? {
        if let task = startRead(url) { await task.value }
        return entries[url]?.pullRequest
    }

    /// Whether `url` is worth reading: never read, or its last read is old enough. A link that
    /// answered is re-read after `freshness`; one that has never answered waits `retry`, so a
    /// rate limit is not met with another call a minute later.
    private func stale(_ url: URL) -> Bool {
        guard let entry = entries[url], let tried = entry.tried else { return true }
        return ContinuousClock.now - tried >= (entry.pullRequest == nil ? retry : freshness)
    }

    /// The read running for `url`, a new one when it is stale, else nil.
    private func startRead(_ url: URL) -> Task<Void, Never>? {
        if let task = inflight[url] { return task }
        guard stale(url) else { return nil }
        let task = fetch([url], as: .visible)
        inflight[url] = task
        return task
    }

    /// Reads `urls` off the main actor and lands their answers in the cache as one `workClass` task; the
    /// returned task ends once they landed (or the scheduler dropped them), so a waiter reads the cache then.
    ///
    /// One link is read the same way ``register(_:)`` reads a reply's: the batched GraphQL read with
    /// a batch of one, not `gh pr view <url>`. It is the same single call to GitHub, and it is the
    /// only one of the two that reads the base branch's checks — a card refreshed through
    /// `gh pr view` would quietly lose "also red on base" sixty seconds after it gained it. A link
    /// on another host (GitHub Enterprise) still falls back to `gh pr view` inside that read.
    private func fetch(_ urls: [URL], as workClass: BudgetedWorkClass) -> Task<Void, Never> {
        let reader = reader, mainWork = mainWork, owner = owner, addresses = urls.map(\.absoluteString)
        let absorb: @MainActor @Sendable ([String: AgentPanePullRequest?]) -> Void = { [weak self] answers in
            self?.absorb(answers, for: urls)
        }
        // task-owner: one read for every link asked at once, off main; everyone waiting on it shares this task.
        return Task { @concurrent in
            let answers = await reader.read(urls: addresses)
            // Abandoned only when the scheduler itself is gone (released with the task unrun): nothing is left to show.
            _ = try? await withOnceContinuation { (landed: OnceContinuation<Void, OnceContinuationError>) in
                mainWork.postFromAnyThread(workClass, owner: owner) {
                    absorb(answers)
                    landed.resume(returning: ())
                }
            }
        }
    }

    /// What a batched read answered. A URL GitHub did not answer for (offline, timed out, rate
    /// limited) keeps its last answer, and every URL of the batch counts as tried, so a failed
    /// batch is not asked again at once.
    private func absorb(_ answers: [String: AgentPanePullRequest?], for urls: [URL]) {
        for url in urls { record(answers[url.absoluteString] ?? nil, for: url) }
        trim()
    }

    /// Writes one read's outcome. A read that failed leaves the last good answer and its age
    /// alone: a rate-limited GitHub must not replace the pull request the card is showing.
    private func record(_ pullRequest: AgentPanePullRequest?, for url: URL) {
        var entry = entries[url] ?? Entry(touched: .now)
        entry.tried = .now
        entry.touched = .now
        if let pullRequest {
            entry.pullRequest = pullRequest
            entry.at = Date()
        }
        entries[url] = entry
        inflight[url] = nil
    }

    /// How many links the cache holds, for the test of its bound.
    var kept: Int { entries.count }

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
