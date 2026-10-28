import CmuxNextSettings
public import Foundation

/// What the host has for one pull request link, with the age of it. A card draws from the cache
/// and never waits on a read: a hover of a link the cache has gone stale on (one minute,
/// ``AgentReplyPullRequests``) starts a background refresh, so GitHub sees at most one read a minute for a link no
/// matter how often it is hovered, and the hover itself always draws at once from what is there
/// (Leo 2026-10-20: the old card called GitHub on every hover and ended up showing "GitHub rate
/// limit · resets 9:11 PM" instead of the pull request). A read that fails leaves the last good
/// answer in place, and the card says how old it is.
public nonisolated struct AgentPanePullRequestAnswer: Equatable, Sendable {
    /// The last answer gh gave about this link; nil when it has never answered.
    public var pullRequest: AgentPanePullRequest?
    /// When gh gave that answer, in seconds since 1970; nil with no answer.
    public var fetchedAt: Double?
    /// When the read that gave it began, in seconds since 1970: what it says was true then, so a
    /// pull request the chat closed after this reopens only for a read that began later.
    public var readFrom: Double?
    /// A read is running now, so the page asks the host again shortly instead of giving up.
    public var reading: Bool

    public init(pullRequest: AgentPanePullRequest? = nil, fetchedAt: Double? = nil, readFrom: Double? = nil,
                reading: Bool = false) {
        self.pullRequest = pullRequest
        self.fetchedAt = fetchedAt
        self.readFrom = readFrom
        self.reading = reading
    }
}

/// The pull request of a chat folder's branch, as the chat header's chip shows it (cx-tcwj, Codex
/// desktop's PR chip): read from `gh pr view --json` ``fields``. The chip's popover (cx-ncc.77.1)
/// shows the title, the review decision and each check; a pull request link's hover card
/// (`pr.inspect`) also shows its author.
public nonisolated struct AgentPanePullRequest: Equatable, Sendable {
    /// The `gh pr view --json` fields read.
    public static let fields = "url,number,title,state,isDraft,reviewDecision,mergeable,statusCheckRollup,createdAt,updatedAt,mergedAt,additions,deletions,changedFiles,files,labels,baseRefName,headRefName,author"
    /// The most checks the popover lists.
    static let maximumChecks = 50
    /// The most labels the card shows; the rest are a "+N".
    static let maximumLabels = 12
    /// The most changed files kept. The card only adds their lines up by kind, so a pull request
    /// with more than this many files shows the kinds of the first ones and says so. The batched
    /// read asks GitHub for 100 (`files(first: 100)`), so that is what a card drawn from it has;
    /// this bound is what a `gh pr view`, which answers with every file, is cut down to.
    static let maximumFiles = 600

    /// One check: its name, `passed`, `failed` or `pending`, and its run's page when that is https.
    public struct Check: Equatable, Sendable {
        public var name: String
        public var state: String
        public var url: String?
        /// This check fails the same way at the base branch's tip, so the pull request did not
        /// break it. False whenever nothing is known about the base, which is every `gh pr view`
        /// read: the card claims this only where it has the base's own answer.
        public var onBase: Bool

        public init(name: String, state: String, url: String?, onBase: Bool = false) {
            self.name = name
            self.state = state
            self.url = url
            self.onBase = onBase
        }
    }

    /// One changed file: its path and the lines it added and removed. The card's `+/−` hover adds
    /// these up by kind with the page's one file-kind classifier (webviews `src/fileKinds.ts`).
    public struct ChangedFile: Equatable, Sendable {
        public var path: String
        public var additions: Int
        public var deletions: Int

        public init(path: String, additions: Int, deletions: Int) {
            self.path = path
            self.additions = additions
            self.deletions = deletions
        }
    }

    /// Its checks summed: `failing` when any failed, else `pending` when any has not finished, else
    /// `passing`, or `none` without checks. A skipped or neutral check counts as passed.
    public struct Checks: Equatable, Sendable {
        public var state: String
        public var passed: Int
        public var total: Int
        /// How many of the failing checks fail at the base branch's tip too, so a reader can tell
        /// "3 failing" from "3 failing, all of them already red on feat-cmux-next". 0 when nothing
        /// is known about the base.
        public var failingOnBase: Int

        public init(state: String, passed: Int, total: Int, failingOnBase: Int = 0) {
            self.state = state
            self.passed = passed
            self.total = total
            self.failingOnBase = failingOnBase
        }
    }

    /// Always https.
    public var url: String
    public var number: Int
    public var title: String
    /// `open`, `draft`, `merged` or `closed`.
    public var state: String
    /// `approved`, `changes_requested`, `review_required`, or empty without a required review.
    public var review: String
    /// `mergeable`, `conflicting`, or empty while GitHub works it out.
    public var mergeable: String
    public var checks: Checks
    /// Each check, failed first, then running, then passed, at most ``maximumChecks``.
    public var checkList: [Check]
    /// When it was opened, last touched and merged, as GitHub's ISO 8601 text; empty when unknown
    /// or not merged. Agent PR cycle time runs between opened and merged (hq#1920).
    public var createdAt: String
    public var updatedAt: String
    public var mergedAt: String
    /// Lines added and removed; 0 when gh did not say.
    public var additions: Int
    public var deletions: Int
    /// Files changed as GitHub counts them, which can be more than ``files`` holds.
    public var changedFiles: Int
    /// Each changed file with its own counts, at most ``maximumFiles``.
    public var files: [ChangedFile]
    /// Its labels' names, at most ``maximumLabels``.
    public var labels: [String]
    /// The branch it merges into and the branch it merges from; empty when gh did not say.
    public var baseRef: String
    public var headRef: String
    /// Its author's GitHub login; empty when gh does not say.
    public var author: String
    /// Its comments, review comments included (GraphQL `totalCommentsCount`); nil when the read
    /// did not say, as a `gh pr view` does not (the Inspector's Changes shows it beside a bubble).
    public var comments: Int?

    public init(url: String, number: Int, title: String = "", state: String, review: String = "", mergeable: String = "",
                checks: Checks, checkList: [Check] = [], createdAt: String = "", updatedAt: String = "", mergedAt: String = "",
                additions: Int = 0, deletions: Int = 0, changedFiles: Int = 0, files: [ChangedFile] = [],
                labels: [String] = [], baseRef: String = "", headRef: String = "", author: String = "",
                comments: Int? = nil) {
        self.url = url
        self.number = number
        self.title = title
        self.state = state
        self.review = review
        self.mergeable = mergeable
        self.checks = checks
        self.checkList = checkList
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.mergedAt = mergedAt
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.files = files
        self.labels = labels
        self.baseRef = baseRef
        self.headRef = headRef
        self.author = author
        self.comments = comments
    }

    /// Nil unless `ghView` is gh's answer with an https url and a number.
    public init?(ghView: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: ghView) as? [String: Any],
              let url = object["url"] as? String, url.hasPrefix("https://"), !url.contains(where: \.isWhitespace),
              let number = object["number"] as? Int else { return nil }
        let state = (object["state"] as? String)?.lowercased() ?? "open"
        let rollup = object["statusCheckRollup"] as? [[String: Any]] ?? []
        // The base branch's tip as the batched read answers it (`baseStatusCheckRollup`); a
        // `gh pr view` cannot read it, so there it is absent and no check is marked.
        let onBase = Self.failing(object["baseStatusCheckRollup"] as? [[String: Any]] ?? [])
        let mergeable = (object["mergeable"] as? String)?.lowercased() ?? ""
        self.init(url: url, number: number, title: object["title"] as? String ?? "",
                  state: state == "open" && object["isDraft"] as? Bool == true ? "draft" : state,
                  review: (object["reviewDecision"] as? String)?.lowercased() ?? "",
                  mergeable: mergeable == "unknown" ? "" : mergeable,
                  checks: Self.checks(rollup, failingOnBase: onBase),
                  checkList: Self.checkList(rollup, failingOnBase: onBase),
                  createdAt: object["createdAt"] as? String ?? "", updatedAt: object["updatedAt"] as? String ?? "",
                  mergedAt: object["mergedAt"] as? String ?? "",
                  additions: object["additions"] as? Int ?? 0, deletions: object["deletions"] as? Int ?? 0,
                  changedFiles: object["changedFiles"] as? Int ?? 0, files: Self.files(object["files"]),
                  labels: Self.labels(object["labels"]),
                  baseRef: Self.branch(object["baseRefName"]), headRef: Self.branch(object["headRefName"]),
                  author: ((object["author"] as? [String: Any])?["login"] as? String).map { String($0.prefix(100)) } ?? "",
                  comments: (object["totalCommentsCount"] as? Int).map { max(0, $0) })
    }

    /// gh's `files`, each with its own counts, at most ``maximumFiles``.
    static func files(_ raw: Any?) -> [ChangedFile] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.prefix(maximumFiles).compactMap { row in
            guard let path = row["path"] as? String, !path.isEmpty, path.utf8.count <= 1024 else { return nil }
            return ChangedFile(path: path, additions: row["additions"] as? Int ?? 0, deletions: row["deletions"] as? Int ?? 0)
        }
    }

    /// gh's `labels`, by name, at most ``maximumLabels``.
    static func labels(_ raw: Any?) -> [String] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { ($0["name"] as? String).map { String($0.prefix(60)) } }
            .filter { !$0.isEmpty }
            .prefix(maximumLabels)
            .map(\.self)
    }

    /// A branch name as the card prints it.
    static func branch(_ raw: Any?) -> String {
        (raw as? String).map { String($0.prefix(200)) } ?? ""
    }

    /// A check's name, whichever kind of context it is.
    static func name(_ check: [String: Any]) -> String {
        (check["name"] as? String) ?? (check["context"] as? String) ?? "check"
    }

    /// The workflow a context belongs to and the run it came from, or nil for a context that
    /// belongs to no run (a commit status, or a `gh pr view` answer, which does not read them).
    private static func runOf(_ check: [String: Any]) -> (workflow: String, run: Int)? {
        guard let suite = check["checkSuite"] as? [String: Any],
              let run = suite["workflowRun"] as? [String: Any],
              let id = run["databaseId"] as? Int else { return nil }
        let workflow = (run["workflow"] as? [String: Any]).flatMap { workflow in
            (workflow["databaseId"] as? Int).map(String.init) ?? workflow["name"] as? String
        }
        return (workflow ?? "", id)
    }

    /// A check's identity across two commits: the workflow it belongs to, and its name.
    ///
    /// The name alone is not enough. Job labels repeat across workflows — this repository has
    /// `test`, `web`, `build`, `check` and `comment` in several — so matching `test` of one
    /// workflow against `test` of another would excuse a red the pull request does cause. A
    /// context that belongs to no run (a commit status, or a `gh pr view` answer, which does not
    /// read runs) identifies by its name alone, and so matches only another context with no run.
    static func identity(_ check: [String: Any]) -> String {
        "\(runOf(check)?.workflow ?? "")\u{0}\(name(check))"
    }

    /// `rollup` with the contexts of every run that a newer run of the same workflow replaced
    /// dropped. Read the warning before using it on anything but a base branch's tip.
    ///
    /// A commit's rollup still lists the checks of a run the concurrency group cancelled when a
    /// newer run of that workflow started on the same commit, and those read as failures
    /// (``outcome(_:)`` has no CANCELLED case on purpose: a cancellation a person asked for is a
    /// red). Keeping only each workflow's highest run id is what tells the two apart. A context
    /// with no run cannot have been superseded, so it stays.
    ///
    /// It is a one-way measure, which is why only ``failing(_:)`` uses it. Two runs of one
    /// workflow on one commit are not always a supersession: a workflow with both a `push` and a
    /// `pull_request` trigger whose concurrency groups differ runs twice and both runs stand, and
    /// a dispatched or rescued re-run outranks the run it stands beside without cancelling it.
    /// Dropping the older of those on a base tip can only fail to excuse a red, which is the safe
    /// direction; doing it to a pull request's own rollup would drop a red it does cause.
    static func latestRuns(_ rollup: [[String: Any]]) -> [[String: Any]] {
        var newest: [String: Int] = [:]
        for check in rollup {
            guard let run = runOf(check) else { continue }
            newest[run.workflow] = max(newest[run.workflow] ?? run.run, run.run)
        }
        guard !newest.isEmpty else { return rollup }
        return rollup.filter { check in
            guard let run = runOf(check) else { return true }
            return run.run >= (newest[run.workflow] ?? run.run)
        }
    }

    /// The ``identity(_:)`` of every check that a commit's own newest runs report as failed.
    ///
    /// Used for the base branch's tip, to tell a reader which of a pull request's reds it did not
    /// cause. A cancelled run is never evidence, even when it is the newest: it reached no verdict,
    /// so a check whose only base run was cancelled stays the pull request's own red. Nor is one
    /// still running. Every judgement here errs the same way — it can fail to excuse a red, never
    /// excuse one wrongly — because a reader sent to a log that was already red loses minutes,
    /// while a reader told a red is not theirs when it is ships it.
    static func failing(_ rollup: [[String: Any]]) -> Set<String> {
        Set(latestRuns(rollup).lazy
            .filter { outcome($0) == "failed" && conclusionOf($0) != "CANCELLED" }
            .map(identity))
    }

    /// Each check run or commit status with its outcome, failed first; links only when https. A
    /// failing check whose ``identity(_:)`` is in `failingOnBase` is marked as the base branch's
    /// red, not this pull request's. Every context of `rollup` is counted: a pull request's own
    /// rollup is read exactly as GitHub reports it (see ``latestRuns(_:)``).
    static func checkList(_ rollup: [[String: Any]], failingOnBase: Set<String> = []) -> [Check] {
        let order = ["failed": 0, "pending": 1, "passed": 2]
        let list = rollup.map { check in
            let link = (check["detailsUrl"] as? String) ?? (check["targetUrl"] as? String)
            let state = outcome(check)
            return Check(name: name(check),
                         state: state,
                         url: link.flatMap { $0.hasPrefix("https://") && !$0.contains(where: \.isWhitespace) ? $0 : nil },
                         onBase: state == "failed" && failingOnBase.contains(identity(check)))
        }
        let sorted = list.enumerated().sorted { (order[$0.element.state] ?? 3, $0.offset) < (order[$1.element.state] ?? 3, $1.offset) }
        return sorted.prefix(maximumChecks).map(\.element)
    }

    /// A check run (`status`, `conclusion`) or a commit status (`state`), each as passed, failed or
    /// still running, with the failures the base branch's tip shares counted out.
    static func checks(_ rollup: [[String: Any]], failingOnBase: Set<String> = []) -> Checks {
        let outcomes = rollup.map(outcome)
        let state = outcomes.isEmpty ? "none" : outcomes.contains("failed") ? "failing" : outcomes.contains("pending") ? "pending" : "passing"
        let base = failingOnBase.isEmpty ? 0 : rollup.filter { outcome($0) == "failed" && failingOnBase.contains(identity($0)) }.count
        return Checks(state: state, passed: outcomes.filter { $0 == "passed" }.count, total: outcomes.count,
                      failingOnBase: base)
    }

    /// A check run's `conclusion` or a commit status's `state`, upper-cased; empty when neither.
    static func conclusionOf(_ check: [String: Any]) -> String {
        ((check["conclusion"] as? String) ?? (check["state"] as? String) ?? "").uppercased()
    }

    /// One check's outcome: `passed`, `failed` or `pending`.
    static func outcome(_ check: [String: Any]) -> String {
        let status = (check["status"] as? String)?.uppercased()
        let conclusion = conclusionOf(check)
        if let status, status != "COMPLETED" { return "pending" }
        switch conclusion {
        case "SUCCESS", "SKIPPED", "NEUTRAL": return "passed"
        // A stale check run was superseded by one not reported yet, as `gh pr checks` reads it.
        case "PENDING", "EXPECTED", "STALE", "": return "pending"
        default: return "failed"
        }
    }

    var json: JSONValue {
        ["url": .string(url), "number": JSONValue(number), "title": .string(title), "state": .string(state),
         "review": .string(review), "mergeable": .string(mergeable),
         "createdAt": .string(createdAt), "updatedAt": .string(updatedAt), "mergedAt": .string(mergedAt),
         "author": .string(author),
         "comments": comments.map { JSONValue($0) } ?? .null,
         "additions": JSONValue(additions), "deletions": JSONValue(deletions),
         "changedFiles": JSONValue(changedFiles),
         "baseRef": .string(baseRef), "headRef": .string(headRef),
         "labels": .array(labels.map { .string($0) }),
         "files": .array(files.map { file in
             .object(["path": .string(file.path), "additions": JSONValue(file.additions),
                      "deletions": JSONValue(file.deletions)])
         }),
         "checks": ["state": .string(checks.state), "passed": JSONValue(checks.passed), "total": JSONValue(checks.total),
                    "failingOnBase": JSONValue(checks.failingOnBase)],
         "checkList": .array(checkList.map { check in
             var row: [String: JSONValue] = ["name": .string(check.name), "state": .string(check.state)]
             if let url = check.url { row["url"] = .string(url) }
             // Only when true, so a card that knows nothing about the base says nothing.
             if check.onBase { row["onBase"] = .bool(true) }
             return .object(row)
         })]
    }
}
