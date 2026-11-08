public import Foundation
import CmuxNextWakeups

/// Reads the pull request of a folder's branch with the user's GitHub CLI (cx-tcwj):
/// `gh pr view --json` ``AgentPanePullRequest/fields`` in the folder, or one pull request by its
/// link (a hover card's `pr.inspect`). Nil when gh is not installed, there is no such pull
/// request, or gh does not answer in time; it never prompts.
public nonisolated struct AgentChatPullRequestReader: Sendable {
    /// `gh`'s path; nil looks in the App's PATH and the usual install folders.
    var gh: String?
    var timeout: Duration = .seconds(30)
    /// The App's environment, from which gh gets the user's GitHub settings (``githubVariables``).
    var environment: [String: String] = ProcessInfo.processInfo.environment
    /// Runs gh in place of the process, for tests: its arguments and folder in, its output out
    /// (nil for no answer). Nil runs the real gh.
    var runner: Runner?
    /// Counts every call to GitHub this reader makes (``Calls``); nil counts nothing.
    var calls: Calls?

    public init(gh: String? = nil, timeout: Duration = .seconds(30), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.gh = gh
        self.timeout = timeout
        self.environment = environment
    }

    /// Folders an app launched from Finder lacks on its PATH, where gh usually is.
    static let installFolders = ["/opt/homebrew/bin", "/usr/local/bin"]
    /// The user's GitHub settings gh reads from its environment: a token-only or proxied setup has
    /// no chip without them (cx-mb1e0).
    static let githubVariables = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_HOST",
                                  "GH_CONFIG_DIR", "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy"]
    /// gh runs here, two at a time, never on the cooperative pool: each may wait up to `timeout`,
    /// and restoring many chats offline must not fill the pool (cx-mb1e0).
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "header-pull-request"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    public func read(in folder: String) async -> AgentPanePullRequest? {
        await read(arguments: ["pr", "view", "--json", AgentPanePullRequest.fields], in: folder, kind: .view)
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
                   in: home, kind: .view)
    }

    /// The unified diff of the pull request at `url` (`gh pr diff <url>`), for the GitHub page's
    /// diff tab; nil when gh is missing, fails or times out, or the diff is over `limit` bytes. The
    /// same queue, deadline and environment as every other read here.
    public func diff(url: URL, limit: Int = 16 * 1024 * 1024) async -> String? {
        guard let data = await run(["pr", "diff", url.absoluteString, "--color", "never"], in: home, anyExit: false, kind: .diff),
              data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Where a read with no repository runs: gh needs none when the pull request is named by URL.
    private var home: String { environment["HOME"] ?? NSHomeDirectory() }

    /// The pull requests at `urls`, wherever their branches are checked out, by URL. github.com
    /// ones take one `gh api graphql` read per ``batchSize``, never one call per pull request;
    /// another host's (GitHub Enterprise) takes one `gh pr view <url>` each. A URL GitHub answered
    /// for has its pull request, or nil when it has none (gone, or not visible); a URL whose read
    /// failed (offline, timed out, rate limited) is left out, so its last answer stands.
    public func read(urls: [String]) async -> [String: AgentPanePullRequest?] {
        await readBatch(urls: urls).answers
    }

    /// ``read(urls:)``'s answers, with the rate limit the last GraphQL read reported.
    func readBatch(urls: [String]) async -> Batch {
        var targets: [Target] = []
        var others: [String] = []
        for url in urls {
            if let target = Target(url: url) { targets.append(target) } else if url.hasPrefix("https://") { others.append(url) }
        }
        var answers: [String: AgentPanePullRequest?] = [:]
        var rate: RateLimit?
        for start in stride(from: 0, to: targets.count, by: Self.batchSize) {
            // GitHub's points left are under the floor: the next batch would spend what the user's
            // own gh needs (review of #37571 at 664acfbe). The links it held count as tried.
            if let rate, rate.remaining < AgentReplyPullRequests.Budget.hardFloor { break }
            let batch = Array(targets[start..<min(start + Self.batchSize, targets.count)])
            // A missing pull request fails the read but leaves the others' data: read it anyway.
            // github.com explicitly: a GH_HOST the App passes on names the user's Enterprise host.
            let arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=" + Self.query(batch)]
            guard let data = await run(arguments, in: nil, anyExit: true, kind: .read) else { continue }
            answers.merge(Self.pullRequests(fromGraphQL: data, batch)) { $1 }
            rate = Self.rateLimit(fromGraphQL: data) ?? rate
        }
        // In the home folder, like ``read(url:)``: a link on another host names its pull request,
        // so this needs no repository, and the App's own working folder is nobody's repository.
        for url in others {
            if let pullRequest = await read(arguments: ["pr", "view", url, "--json", AgentPanePullRequest.fields], in: home, kind: .view) {
                answers[url] = pullRequest
            }
        }
        return Batch(answers: answers, rate: rate)
    }

    /// The most pull requests one GraphQL read asks for.
    static let batchSize = 50

    /// One pull request a GraphQL read asks for.
    struct Target: Equatable {
        var url: String
        var owner: String
        var name: String
        var number: Int

        /// Nil unless `url` is `https://github.com/<owner>/<repo>/pull/<n>` (or `/issues/<n>`) with
        /// plain names. Both are read as `issueOrPullRequest`: GitHub numbers them in one series,
        /// and a reference written as either may name the other.
        init?(url: String) {
            let parts = url.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let plain = { (s: String) in !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }
            guard parts.count == 7, parts[0] == "https:", parts[1].isEmpty, parts[2] == "github.com", plain(parts[3]), plain(parts[4]),
                  parts[5] == "pull" || parts[5] == "issues", let number = Int(parts[6]), number > 0, String(number) == parts[6] else { return nil }
            self.url = url
            owner = parts[3]
            name = parts[4]
            self.number = number
        }
    }

    /// The query for `targets`: `p<i>` is the i-th one's pull request, with the fields `gh pr view`
    /// reads (``AgentPanePullRequest/fields``) and its last commit's check rollup, and the rate
    /// limit the read leaves (``rateLimitField``).
    static func query(_ targets: [Target]) -> String {
        // Every field ``AgentPanePullRequest/fields`` reads, so a pull request from here is the
        // same pull request a `gh pr view` of it would be: a card drawn from a batched read must
        // not be missing its branches, labels or files.
        // A rollup's contexts carry the run they came from, and both halves of that are read:
        // ``AgentPanePullRequest/identity(_:)`` matches a head check against a base one by its
        // workflow as well as its name, on both sides, and
        // ``AgentPanePullRequest/latestRuns(_:)`` uses the run id on the base side, because a
        // cancelled run a newer run of the same workflow replaced still sits in this list and
        // reads as a failure. The run's event is read too:
        // ``AgentPanePullRequest/counted(_:)`` drops a head run only when a newer run of the same
        // workflow, event and name replaced it. Trimming the run or workflow degrades the match to
        // the name alone, which would excuse a red of one workflow with a same-named red of
        // another; trimming the event only stops head runs from being proven superseded.
        let contexts = """
            contexts(first: 100) { nodes { __typename \
            ... on CheckRun { name status conclusion detailsUrl \
            checkSuite { workflowRun { databaseId event workflow { databaseId name } } } } \
            ... on StatusContext { context state targetUrl } } }
            """
        // Beyond what `gh pr view` reads, the card's extras come in the same call, at no extra
        // cost: each label's color, the author's avatar link (48 px, fetched by
        // ``AgentReplyAvatars``), and the head rollup's own sum, which the probe compares.
        let fields = """
            url number title state isDraft reviewDecision mergeable createdAt updatedAt mergedAt additions deletions totalCommentsCount \
            changedFiles baseRefName headRefName baseRefOid headRefOid author { login avatarUrl(size: 48) } \
            labels(first: \(AgentPanePullRequest.maximumLabels)) { nodes { name color } } \
            files(first: 100) { nodes { path additions deletions } } \
            commits(last: 1) { nodes { commit { statusCheckRollup { state \(Self.rollupCounts) \(contexts) } } } } \
            baseRef { target { ... on Commit { statusCheckRollup { state \(Self.rollupCounts) \(contexts) } } } }
            """
        let aliases = targets.enumerated().map { index, target in
            "p\(index): repository(owner: \"\(target.owner)\", name: \"\(target.name)\") "
                + "{ issueOrPullRequest(number: \(target.number)) { __typename ...f ...i } }"
        }
        return "query { \(rateLimitField) \(aliases.joined(separator: " ")) } fragment f on PullRequest { \(fields) } "
            + "fragment i on Issue { \(Self.issueFields) }"
    }

    /// What a card shows of an issue: its title, state (and why it closed), author, labels and
    /// comment count. An issue has no branches, checks or files.
    static let issueFields = "url number title state stateReason createdAt updatedAt closedAt author { login avatarUrl(size: 48) } "
        + "labels(first: \(AgentPanePullRequest.maximumLabels)) { nodes { name color } } comments { totalCount }"

    /// An issue's node as ``AgentPanePullRequest/init(ghView:)`` reads it: `kind` `issue`, and a
    /// closed one that was not planned under its own state (GitHub draws it grey, not purple).
    static func issueView(_ node: [String: Any]) -> [String: Any] {
        var view = node
        view["kind"] = "issue"
        if (node["state"] as? String)?.uppercased() == "CLOSED", (node["stateReason"] as? String)?.uppercased() == "NOT_PLANNED" {
            view["state"] = "NOT_PLANNED"
        }
        view["totalCommentsCount"] = (node["comments"] as? [String: Any])?["totalCount"] as? Int
        view["comments"] = nil
        // GraphQL wraps a connection's rows in `nodes`; gh prints them as a plain array.
        view["labels"] = (node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        view["__typename"] = nil
        return view
    }

    /// Each target's pull request in a GraphQL answer, reshaped as `gh pr view` prints it (the
    /// rollup's contexts as `statusCheckRollup`), by the target's URL: nil for a target GitHub
    /// answered null for (no such pull request, or not visible); a target the answer does not
    /// mention (no `data`), or whose null comes with an error other than NOT_FOUND (SSO, a resource
    /// limit), is left out, so it keeps its last answer.
    static func pullRequests(fromGraphQL data: Data, _ targets: [Target]) -> [String: AgentPanePullRequest?] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["data"] as? [String: Any] else { return [:] }
        let unanswered = Set(((object["errors"] as? [[String: Any]]) ?? []).compactMap { error -> String? in
            guard (error["type"] as? String) != "NOT_FOUND" else { return nil }
            return (error["path"] as? [Any])?.first as? String
        })
        var result: [String: AgentPanePullRequest?] = [:]
        for (index, target) in targets.enumerated() {
            guard let alias = answers["p\(index)"] else { continue }
            guard var view = (alias as? [String: Any])?["issueOrPullRequest"] as? [String: Any] else {
                if !unanswered.contains("p\(index)") { result[target.url] = .some(nil) }
                continue
            }
            if view["__typename"] as? String == "Issue" {
                guard let data = try? JSONSerialization.data(withJSONObject: Self.issueView(view)),
                      let issue = AgentPanePullRequest(ghView: data) else { continue }
                result[target.url] = .some(issue)
                continue
            }
            let commit = ((view["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.last?["commit"] as? [String: Any]
            let rollup = commit?["statusCheckRollup"] as? [String: Any]
            let contexts = rollup?["contexts"] as? [String: Any]
            view["statusCheckRollup"] = contexts?["nodes"] as? [[String: Any]] ?? []
            // The rollup's sum and counts, which the cheap probe compares (``probeQuery(_:)``).
            view["rollupState"] = Self.rollupFingerprint(rollup)
            view["commits"] = nil
            // The base branch's tip, under the name `AgentPanePullRequest` reads it by. The tip is
            // what "also red on base" means: the merge rules measure a base red there, not at this
            // pull request's merge base.
            let baseTarget = (view["baseRef"] as? [String: Any])?["target"] as? [String: Any]
            let baseRollup = baseTarget?["statusCheckRollup"] as? [String: Any]
            let baseContexts = baseRollup?["contexts"] as? [String: Any]
            view["baseStatusCheckRollup"] = baseContexts?["nodes"] as? [[String: Any]] ?? []
            // What "already red on base" was read from, which the probe compares too.
            view["baseRollupState"] = Self.rollupFingerprint(baseRollup)
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

    private func read(arguments: [String], in folder: String?, kind: Calls.Kind) async -> AgentPanePullRequest? {
        await run(arguments, in: folder, anyExit: false, kind: kind).flatMap(AgentPanePullRequest.init(ghView:))
    }

    /// gh's output for `arguments`, on the queue; nil when gh is missing, fails (unless `anyExit`)
    /// or does not answer in time. Counted as a `kind` call to GitHub once gh runs.
    func run(_ arguments: [String], in folder: String?, anyExit: Bool, kind: Calls.Kind) async -> Data? {
        if let runner {
            calls?.count(kind)
            return await runner(arguments, folder)
        }
        guard let gh = gh ?? Self.findGitHubCLI(environment) else { return nil }
        calls?.count(kind)
        let timeout = timeout, environment = Self.environment(environment)
        return await withCheckedContinuation { continuation in
            Self.queue.addOperation {
                continuation.resume(returning: Self.run(gh, arguments: arguments, in: folder, environment: environment,
                                                        timeout: timeout, anyExit: anyExit))
            }
        }
    }

    /// gh's environment: no prompts, the App's PATH and gh's install folders, HOME, and the user's
    /// GitHub settings.
    static func environment(_ app: [String: String]) -> [String: String] {
        var environment = ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GIT_TERMINAL_PROMPT": "0",
                           "PATH": ([app["PATH"] ?? "/usr/bin:/bin"] + installFolders).joined(separator: ":")]
        environment["HOME"] = app["HOME"]
        for key in githubVariables { environment[key] = app[key] }
        return environment
    }

    public static func findGitHubCLI(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + installFolders
        return folders.filter { $0.hasPrefix("/") }.map { $0 + "/gh" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The process, for the deadline.
    private final class Held: @unchecked Sendable { // crash-allow: one immutable let; the deadline only reads isRunning and calls terminate, which Process allows from any thread
        let process = Process()
    }

    private static func run(_ gh: String, arguments: [String], in folder: String?, environment: [String: String],
                            timeout: Duration, anyExit: Bool) -> Data? {
        let held = Held(), process = held.process
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
        process.environment = environment
        // A file, not a pipe: a child gh left holding its output cannot keep this read (and one of
        // the queue's two runs) waiting past the deadline.
        let file = FileManager.default.temporaryDirectory.appending(path: "cmux-gh-pr-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let output = try? FileHandle(forWritingTo: file) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        try? output.close()
        let deadline = DemandTimer(owner: "header-pull-request")
        deadline.schedule(after: timeout) { if held.process.isRunning { held.process.terminate() } }
        defer { deadline.cancel() }
        // concurrency-allow: run is called only on read's own operation queue, bounded by the deadline above.
        process.waitUntilExit()
        // A deadline kill is never an answer.
        guard process.terminationStatus == 0 || (anyExit && process.terminationReason == .exit) else { return nil }
        return try? Data(contentsOf: file)
    }
}
