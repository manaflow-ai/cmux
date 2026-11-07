public import Foundation
public import CmuxNextSettings
import CmuxNextAgentPane

/// A pull request's checks as the GitHub page's CI dashboard draws them (Leo, 2026-11-07: "here's
/// your big dashboard"): every job at the head with its state, start and end, the workflow run it
/// belongs to, and how long the same job took at the base branch's tip (the ETA). One
/// `gh api graphql` read; ``GitHubPageProvider`` keeps it for a time that depends on its state
/// (``freshness``), shared by every page showing the pull request, so a page that asks every few
/// seconds is not a read every few seconds and the cost does not grow with the pull requests open.
public nonisolated struct GitHubChecks: Equatable, Sendable {
    public struct Job: Equatable, Sendable {
        /// The check run's id, which is its Actions job id; 0 for a commit status.
        public var id: Int
        public var name: String
        /// The workflow's name, empty for a commit status or another app's check.
        public var workflow: String
        /// The Actions run it belongs to (what Re-run failed reruns), nil when none.
        public var run: Int?
        /// The event that started its run (`push`, `pull_request`), empty for a commit status:
        /// one workflow's runs for two events are two executions, each with its own rows.
        public var event = ""
        /// `passed`, `failed`, `running`, `queued` or `skipped`.
        public var state: String
        public var startedAt: String
        public var completedAt: String
        public var url: String?
        /// Seconds the same job took at the base branch's tip, nil when it did not run there.
        public var expected: Double?
        /// The failing step and the end of its log (``GitHubJobFailure``), for a failed job once read.
        public var failure: GitHubJobFailure?
    }

    public var head: String
    public var jobs: [Job]
    /// GitHub has more suites or check runs than one read takes (``maximumSuites``, ``maximumRuns``):
    /// `jobs` is not every job, so the set is never settled and the page says more exist.
    public var truncated = false

    /// Every job is done (or there are none) and all were read: nothing will change until a push or a re-run.
    public var settled: Bool { !truncated && jobs.allSatisfy { $0.state != "running" && $0.state != "queued" } }

    /// How long a read stays fresh: a running pull request is read again soon, a settled one rarely.
    public var freshness: Duration { settled ? .seconds(300) : .seconds(20) }

    static let maximumSuites = 40
    static let maximumRuns = 100

    /// GraphQL's non-null mark, spelled apart so the crash ratchet does not read it as an unwrap.
    private static let required = "!"
    /// `checkType: LATEST` drops a re-run's earlier attempts within a suite; an earlier suite of the
    /// same workflow (by id, not its display name) and event (the commit pushed again) is dropped in
    /// ``parse(_:)``. `hasNextPage` says the read was cut short.
    static let query = """
        query($owner: String\(required), $name: String\(required), $number: Int\(required)) { repository(owner: $owner, name: $name) {
          pullRequest(number: $number) { headRefOid
            commits(last: 1) { nodes { commit {
              checkSuites(first: \(maximumSuites)) { pageInfo { hasNextPage } nodes { workflowRun { databaseId event workflow { databaseId name } }
                checkRuns(first: \(maximumRuns), filterBy: { checkType: LATEST }) { pageInfo { hasNextPage } nodes {
                  databaseId name status conclusion startedAt completedAt detailsUrl } } } }
              status { contexts { context state targetUrl createdAt } } } } }
            baseRef { target { ... on Commit { checkSuites(first: \(maximumSuites)) { nodes { workflowRun { workflow { databaseId name } }
              checkRuns(first: \(maximumRuns), filterBy: { checkType: LATEST, status: COMPLETED }) { nodes {
                name conclusion startedAt completedAt } } } } } } } } } }
        """

    static func arguments(for link: GitHubLink) -> [String] {
        let parts = link.repository.split(separator: "/").map(String.init)
        return ["api", "graphql", "--hostname", "github.com", "-f", "owner=\(parts.first ?? "")", "-f", "name=\(parts.last ?? "")",
                "-F", "number=\(link.number)", "-f", "query=\(query)"]
    }

    @concurrent public static func read(_ link: GitHubLink) async -> GitHubChecks? {
        guard let data = await AgentPaneGitPullRequest.pageRead(arguments(for: link)) else { return nil }
        return parse(data)
    }

    /// A check run's state as the dashboard groups it.
    static func state(status: String?, conclusion: String?) -> String {
        switch status?.uppercased() {
        case "IN_PROGRESS": return "running"
        case "QUEUED", "WAITING", "PENDING", "REQUESTED": return "queued"
        default: break
        }
        switch conclusion?.uppercased() {
        case "SUCCESS", "NEUTRAL": return "passed"
        case "SKIPPED": return "skipped"
        case nil, "": return "queued"
        default: return "failed"
        }
    }

    static func parse(_ data: Data) -> GitHubChecks? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let repository = (object["data"] as? [String: Any])?["repository"] as? [String: Any],
              let pull = repository["pullRequest"] as? [String: Any] else { return nil }
        let nodes = { (value: Any?) in ((value as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] }
        let workflow = { (suite: [String: Any]) in (suite["workflowRun"] as? [String: Any])?["workflow"] as? [String: Any] }
        let more = { (value: Any?) in (((value as? [String: Any])?["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool) == true }
        // How long each job took at the base's tip, by workflow id and name; only a passing one says how long it takes.
        var expected: [String: Double] = [:]
        let baseTarget = (pull["baseRef"] as? [String: Any])?["target"] as? [String: Any]
        for suite in nodes(baseTarget?["checkSuites"]) {
            guard let id = workflow(suite)?["databaseId"] as? Int else { continue }
            for run in nodes(suite["checkRuns"]) where (run["conclusion"] as? String)?.uppercased() == "SUCCESS" {
                guard let name = run["name"] as? String, let seconds = duration(run["startedAt"], run["completedAt"]) else { continue }
                expected["\(id)\u{0}\(name)"] = seconds
            }
        }
        let commit = nodes(pull["commits"]).last?["commit"] as? [String: Any]
        var truncated = more(commit?["checkSuites"])
        var latest: [String: Job] = [:]
        var order: [String] = []
        for (index, suite) in nodes(commit?["checkSuites"]).enumerated() {
            let name = workflow(suite)?["name"] as? String ?? ""
            let id = workflow(suite)?["databaseId"] as? Int
            let run = (suite["workflowRun"] as? [String: Any])?["databaseId"] as? Int
            let event = (suite["workflowRun"] as? [String: Any])?["event"] as? String ?? ""
            truncated = truncated || more(suite["checkRuns"])
            for (position, check) in nodes(suite["checkRuns"]).enumerated() {
                guard let job = check["name"] as? String, !job.isEmpty else { continue }
                // One workflow (by id: two workflows may share a name) and event is one execution, run
                // again by a push; another app's check run has no workflow and is never merged.
                let key = id.map { "run\u{0}\($0)\u{0}\(event)\u{0}\(job)" } ?? "app\u{0}\(index)\u{0}\(position)"
                let row = Job(id: check["databaseId"] as? Int ?? 0, name: job, workflow: name, run: run, event: event,
                              state: state(status: check["status"] as? String, conclusion: check["conclusion"] as? String),
                              startedAt: check["startedAt"] as? String ?? "", completedAt: check["completedAt"] as? String ?? "",
                              url: link(check["detailsUrl"]), expected: id.flatMap { expected["\($0)\u{0}\(job)"] })
                // The same job of the same execution again (the commit pushed again): the newest run
                // stands, by GitHub's ids, which only grow; a queued one with no start yet still wins.
                if let kept = latest[key], ((kept.run ?? 0), kept.id) >= ((row.run ?? 0), row.id) { continue }
                if latest[key] == nil { order.append(key) }
                latest[key] = row
            }
        }
        // GitHub gives each status context once, its latest state.
        let contexts = ((commit?["status"] as? [String: Any])?["contexts"] as? [[String: Any]]) ?? []
        for context in contexts {
            guard let name = context["context"] as? String, !name.isEmpty else { continue }
            let key = "status\u{0}\(name)"
            let state: String = switch (context["state"] as? String)?.uppercased() {
            case "SUCCESS": "passed"
            case "PENDING", "EXPECTED": "running"
            default: "failed"
            }
            if latest[key] == nil { order.append(key) }
            latest[key] = Job(id: 0, name: name, workflow: "", run: nil, state: state, startedAt: context["createdAt"] as? String ?? "",
                              completedAt: "", url: link(context["targetUrl"]), expected: nil)
        }
        return GitHubChecks(head: pull["headRefOid"] as? String ?? "", jobs: order.compactMap { latest[$0] }, truncated: truncated)
    }

    /// Seconds from `start` to `end` (ISO 8601), nil unless both parse.
    static func duration(_ start: Any?, _ end: Any?) -> Double? {
        let format = ISO8601DateFormatter()
        guard let start = (start as? String).flatMap(format.date(from:)), let end = (end as? String).flatMap(format.date(from:)),
              end >= start else { return nil }
        return end.timeIntervalSince(start)
    }

    private static func link(_ value: Any?) -> String? {
        guard let text = value as? String, text.hasPrefix("https://"), !text.contains(where: \.isWhitespace) else { return nil }
        return text
    }

    public var json: JSONValue {
        .object(["head": .string(head), "settled": .bool(settled), "truncated": .bool(truncated), "jobs": .array(jobs.map { job in
            var row: [String: JSONValue] = ["id": JSONValue(job.id), "name": .string(job.name), "workflow": .string(job.workflow),
                                            "state": .string(job.state), "startedAt": .string(job.startedAt),
                                            "completedAt": .string(job.completedAt)]
            if let run = job.run { row["run"] = JSONValue(run) }
            if !job.event.isEmpty { row["event"] = .string(job.event) }
            if let url = job.url { row["url"] = .string(url) }
            if let expected = job.expected { row["expected"] = .number(expected) }
            if let failure = job.failure {
                row["failure"] = .object(["step": failure.step.map(JSONValue.string) ?? .null, "excerpt": .string(failure.excerpt)])
            }
            return .object(row)
        })])
    }
}

/// Why a failed job failed: its first failing step and the end of its log up to the last error.
/// Read once per job id (a finished job's log does not change) and only for failed jobs.
public nonisolated struct GitHubJobFailure: Equatable, Sendable {
    public var step: String?
    public var excerpt: String

    /// The most lines and characters an excerpt keeps.
    static let maximumLines = 24
    static let maximumCharacters = 4_000
    /// The most of a log read: its end, where the error is.
    static let maximumLog = 512 * 1024

    @concurrent static func read(repository: String, job: Int) async -> GitHubJobFailure? {
        guard job > 0, repository.split(separator: "/").count == 2 else { return nil }
        let detail = await AgentPaneGitPullRequest.pageRead(["api", "repos/\(repository)/actions/jobs/\(job)"])
        var log = await AgentPaneGitPullRequest.pageRead(logArguments(repository: repository, job: job, tail: true))
        if log == nil { log = await AgentPaneGitPullRequest.pageRead(logArguments(repository: repository, job: job, tail: false)) }
        guard detail != nil || log != nil else { return nil }
        return GitHubJobFailure(step: detail.flatMap(failingStep), excerpt: log.map { excerpt(of: $0) } ?? "")
    }

    /// The log read. `tail`: only its end, a Range for the last ``maximumLog`` bytes, which rides gh's
    /// redirect to the log's storage; a store that refuses it gets the whole log once, and
    /// ``excerpt(of:)`` keeps the end either way.
    static func logArguments(repository: String, job: Int, tail: Bool) -> [String] {
        let logs = "repos/\(repository)/actions/jobs/\(job)/logs"
        return tail ? ["api", "-H", "Range: bytes=-\(maximumLog)", logs] : ["api", logs]
    }

    /// The first step whose conclusion is a failure, in a `GET actions/jobs/:id` answer.
    static func failingStep(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = object["steps"] as? [[String: Any]] else { return nil }
        return steps.first { ["failure", "timed_out", "cancelled"].contains(($0["conclusion"] as? String)?.lowercased() ?? "") }?["name"] as? String
    }

    /// The lines before and at the log's last `##[error]` (else its last lines), without the
    /// runner's timestamps, at most ``maximumLines`` and ``maximumCharacters``.
    static func excerpt(of data: Data) -> String {
        let tail = data.count > maximumLog ? data.suffix(maximumLog) : data
        let text = String(decoding: tail, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var line = String(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            // `2026-11-07T08:01:02.1234567Z text`: the runner's timestamp says nothing here.
            if line.count > 29, line.prefix(4).allSatisfy(\.isNumber), let space = line.firstIndex(of: " "),
               line.distance(from: line.startIndex, to: space) <= 30 {
                line = String(line[line.index(after: space)...])
            }
            return line
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let end = (lines.lastIndex { $0.contains("##[error]") }).map { $0 + 1 } ?? lines.count
        let kept = lines[max(0, end - maximumLines)..<end].map { $0.replacingOccurrences(of: "##[error]", with: "") }
        let joined = kept.joined(separator: "\n")
        return joined.count > maximumCharacters ? String(joined.suffix(maximumCharacters)) : joined
    }
}
