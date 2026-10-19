public import Foundation
import CmuxNextWakeups

/// Reads the pull request of a folder's branch with the user's GitHub CLI (cx-tcwj):
/// `gh pr view --json` ``AgentPanePullRequest/fields`` in the folder. Nil when gh is not installed,
/// the branch has no pull request, or gh does not answer in time; it never prompts.
public nonisolated struct AgentChatPullRequestReader: Sendable {
    /// `gh`'s path; nil looks in the App's PATH and the usual install folders.
    var gh: String?
    var timeout: Duration = .seconds(30)
    /// The App's environment, from which gh gets the user's GitHub settings (``githubVariables``).
    var environment: [String: String] = ProcessInfo.processInfo.environment

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
        await read(arguments: ["pr", "view", "--json", AgentPanePullRequest.fields], in: folder)
    }

    /// The pull requests at `urls`, wherever their branches are checked out, by URL. github.com
    /// ones take one `gh api graphql` read per ``batchSize``, never one call per pull request;
    /// another host's (GitHub Enterprise) takes one `gh pr view <url>` each. A URL GitHub answered
    /// for has its pull request, or nil when it has none (gone, or not visible); a URL whose read
    /// failed (offline, timed out, rate limited) is left out, so its last answer stands.
    public func read(urls: [String]) async -> [String: AgentPanePullRequest?] {
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
        for url in others {
            if let pullRequest = await read(arguments: ["pr", "view", url, "--json", AgentPanePullRequest.fields], in: nil) {
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
        let fields = """
            url number title state isDraft reviewDecision mergeable createdAt mergedAt additions deletions \
            commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes { __typename \
            ... on CheckRun { name status conclusion detailsUrl } ... on StatusContext { context state targetUrl } } } } } } }
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
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
            guard let reshaped = try? JSONSerialization.data(withJSONObject: view),
                  let pullRequest = AgentPanePullRequest(ghView: reshaped) else { continue }
            result[target.url] = .some(pullRequest)
        }
        return result
    }

    private func read(arguments: [String], in folder: String?) async -> AgentPanePullRequest? {
        await run(arguments, in: folder, anyExit: false).flatMap(AgentPanePullRequest.init(ghView:))
    }

    /// gh's output for `arguments`, on the queue; nil when gh is missing, fails (unless `anyExit`)
    /// or does not answer in time.
    private func run(_ arguments: [String], in folder: String?, anyExit: Bool) async -> Data? {
        guard let gh = gh ?? Self.findGitHubCLI(environment) else { return nil }
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

    static func findGitHubCLI(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + installFolders
        return folders.filter { $0.hasPrefix("/") }.map { $0 + "/gh" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The process, for the deadline.
    private final class Held: @unchecked Sendable { // crash-allow: holds only a Process; the deadline calls only isRunning and terminate(), which Foundation makes thread-safe
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
