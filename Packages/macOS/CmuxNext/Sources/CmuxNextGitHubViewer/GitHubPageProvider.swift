public import AppKit
public import CmuxNextAgentPane
public import CmuxNextPages
public import CmuxNextSettings

/// The owner side of the GitHub page (`cmux.github.*`).
/// - `pr.inspect {url, cached?}`, `browser.list {}`, `browser.openIn {url, browserId}`: the agent page's
///   link card methods (``AgentPaneReplyLinks/cardMethods``), answered the same way: the pull request
///   from ``AgentReplyPullRequests`` (never waits; a stale one is read again in the background), and
///   Open on GitHub, which opens the web page through `openWeb` and spends the person's gesture.
/// - `shown {url, content}`: the page drew `url`'s pull request (`content`) or its loading or
///   failure state; reported to ``onShown`` (the instant-create bench's mark).
/// - `diff.open {url, file?}`: the pull request's diff (`gh pr diff`) in the diff viewer, scrolled to
///   `file`. Spends the gesture. The diff is read in the background when the page first asks about
///   the pull request, and kept until the pull request's `updatedAt` moves, so the click opens it at once.
///   It is read from the pull request's commits on this Mac when a chat folder has them
///   (``GitHubLocalDiff``), else from GitHub.
/// - `diff.file {url, file}`: one file's part of that same diff (`{patch}`, null when the diff has
///   no such file or it is too long to draw inline), for a file the page expands in place. No
///   gesture: it reads only what `diff.open` would show.
/// - `pr.details {url}`: the body, conversation, reviewers, closed issues, label colours, head
///   commit and merge state (``GitHubPullRequestDetails``): one read per pull request kept until
///   its `updatedAt` moves, and never more than one a minute, however often the page asks.
/// - `pr.merge {url, head}`: merges the pull request through GitHub's normal merge path, pinned
///   to `head`, the commit the page showed (``AgentPaneGitPullRequest/mergeShown(url:head:)``).
///   Spends the gesture.
/// - `checks.read {url, head?}`: the CI dashboard's jobs (``GitHubChecks``) at `head`, the commit
///   the page shows, from the App's one checks cache (``GitHubChecksCache``), read again only when
///   stale for its state or kept for another head; never another head's checks.
/// - `checks.rerun {url, runs}`: re-runs the failed jobs of those Actions runs (`gh run rerun
///   --failed`), only runs the dashboard showed with a failed job. Spends the gesture.
@MainActor
public final class GitHubPageProvider: PageProvider {
    public static let namespace = "cmux.github."

    /// A pull request's diff, read once per `updatedAt`.
    private struct Diff {
        let updatedAt: String
        let read: Task<String?, Never>
        /// The read tries this Mac's commits first (``GitHubLocalDiff``).
        var local = false
    }

    private let links: AgentPaneReplyLinks
    private let cache: AgentReplyPullRequests
    private let diffReader: @Sendable (URL) async -> String?
    private let localDiff: GitHubLocalDiff?
    private let openWeb: @MainActor (URL, NSView?) -> Bool
    private let openDiff: @MainActor (_ text: String, _ link: GitHubLink, _ file: String?, _ from: NSView?) -> Bool
    private var diffs: [URL: Diff] = [:]
    private let detailsReader: @Sendable (GitHubLink) async -> GitHubPullRequestDetails?
    private let merger: @Sendable (_ url: String, _ head: String) async -> AgentPaneGitPullRequest.PageMerge
    /// A pull request's details, read once per `updatedAt` (and at most once per ``detailsFreshness``).
    private struct Details {
        let updatedAt: String
        let began: ContinuousClock.Instant
        let read: Task<GitHubPullRequestDetails?, Never>
        /// The read answered: kept while `updatedAt` stays.
        var good = false
    }
    private var details: [URL: Details] = [:]
    private let checksCache: GitHubChecksCache
    private let rerunner: @Sendable (_ repository: String, _ run: Int) async -> String?
    static let detailsFreshness: Duration = .seconds(60)
    /// The longest one file's patch drawn inline; a longer one opens in the diff viewer.
    static let maximumInlinePatch = 512 * 1024
    /// The gesture the last open spent: one key or click opens one thing.
    private var spentGesture: TimeInterval?
    /// The page drew `url`: its pull request when `content`, else its loading or failure state.
    public var onShown: @MainActor (_ url: String, _ content: Bool) -> Void = { _, _ in }
    /// The page view, so what it opens lands beside the pane that shows it.
    public var anchor: @MainActor () -> NSView? = { nil }

    /// The most diffs kept; the page shows one pull request at a time.
    static let maximumDiffs = 8

    public init(cache: AgentReplyPullRequests = .shared,
                diffReader: @escaping @Sendable (URL) async -> String?,
                localDiff: GitHubLocalDiff? = nil,
                detailsReader: (@Sendable (GitHubLink) async -> GitHubPullRequestDetails?)? = nil,
                merger: (@Sendable (_ url: String, _ head: String) async -> AgentPaneGitPullRequest.PageMerge)? = nil,
                checks: GitHubChecksCache? = nil,
                rerunner: (@Sendable (_ repository: String, _ run: Int) async -> String?)? = nil,
                openWeb: @escaping @MainActor (URL, NSView?) -> Bool,
                openDiff: @escaping @MainActor (_ text: String, _ link: GitHubLink, _ file: String?, _ from: NSView?) -> Bool) {
        self.cache = cache
        self.diffReader = diffReader
        self.localDiff = localDiff
        // Nil: the user's gh (tests pass their own).
        self.detailsReader = detailsReader ?? { await GitHubPullRequestDetails.read($0) }
        self.merger = merger ?? { await AgentPaneGitPullRequest.mergeShown(url: $0, head: $1) }
        // Nil: a cache of its own (tests); the App passes its one cache so pages share reads.
        checksCache = checks ?? GitHubChecksCache()
        self.rerunner = rerunner ?? { await AgentPaneGitPullRequest.rerunFailed(repository: $0, run: $1) }
        self.openWeb = openWeb
        self.openDiff = openDiff
        let links = AgentPaneReplyLinks()
        links.pullRequest = { cache.answer($0) }
        links.cachedPullRequest = { cache.answer($0, read: false) }
        self.links = links
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op.hasPrefix(Self.namespace) else { throw PageError.unknownOp(op) }
        let method = String(op.dropFirst(Self.namespace.count))
        if method == "diff.open" { return try await openDiff(params, context: context) }
        if method == "diff.file" { return try await diffFile(params) }
        if method == "pr.details" { return try await readDetails(params) }
        if method == "pr.merge" { return try await merge(params, context: context) }
        if method == "checks.read" { return try await readChecks(params) }
        if method == "checks.rerun" { return try await rerun(params, context: context) }
        if method == "shown" {
            onShown(params["url"]?.stringValue ?? "", params["content"]?.boolValue == true)
            return .null
        }
        guard AgentPaneReplyLinks.cardMethods.contains(method),
              let request = AgentPaneReplyRequest(method: method, params: params.foundationObject as? [String: Any]) else {
            throw AgentPaneReplyLinks.cardMethods.contains(method) ? PageError.invalidParams(op) : PageError.unknownOp(op)
        }
        if case .openIn(let url, _) = request, url.scheme?.lowercased() != "https" {
            throw PageError.invalidParams("\(op) opens only https links")
        }
        if case .inspectPullRequest(let url, cached: false) = request, let link = GitHubLink(url) { prefetchDiff(link) }
        let reply = links.respond(toCard: request, consumeGesture: { spendGesture(context) },
                                  openInCmux: { [anchor, openWeb] url in openWeb(url, anchor()) })
        return try AgentPageProvider.value(of: reply)
    }

    /// Starts reading `link`'s diff unless one for its current `updatedAt` is kept or running.
    func prefetchDiff(_ link: GitHubLink) {
        let updatedAt = cache.answer(link.url, read: false).pullRequest?.updatedAt ?? ""
        if let kept = diffs[link.url] {
            if kept.updatedAt == updatedAt || updatedAt.isEmpty { return }
            // A read started before the cache had the pull request is as new as its first `updatedAt`;
            // now that its commits are known, this Mac's are tried before that read's answer.
            if kept.updatedAt.isEmpty {
                guard !kept.local, let local = localDiff, let plan = local.plan(link) else {
                    diffs[link.url] = Diff(updatedAt: updatedAt, read: kept.read, local: kept.local)
                    return
                }
                let earlier = kept.read
                // task-owner: replaces the kept read for this updatedAt; the earlier read's answer is its fallback.
                diffs[link.url] = Diff(updatedAt: updatedAt, read: Task.detached(priority: .userInitiated) {
                    if let text = await local.diff(plan) { return text }
                    return await earlier.value
                }, local: true)
                return
            }
        }
        let reader = diffReader, url = link.url, local = localDiff, plan = localDiff?.plan(link)
        // task-owner: one diff read per pull request and updatedAt; diff.open awaits it, a newer updatedAt replaces it.
        // Detached: the read decodes up to 16 MB, never on the main thread (the local read hops to it only to send).
        diffs[link.url] = Diff(updatedAt: updatedAt, read: Task.detached(priority: .userInitiated) {
            if let local, let plan, let text = await local.diff(plan) { return text }
            return await reader(url)
        }, local: plan != nil)
        while diffs.count > Self.maximumDiffs, let other = diffs.keys.first(where: { $0 != link.url }) { diffs[other] = nil }
    }

    private func openDiff(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let address = params["url"]?.stringValue, let url = URL(string: address), let link = GitHubLink(url) else {
            throw PageError.invalidParams("cmux.github.diff.open needs a pull request url")
        }
        let file = params["file"]?.stringValue.flatMap { $0.isEmpty || $0.utf8.count > 4096 ? nil : $0 }
        guard spendGesture(context) else { throw PageError(code: "cmux.github.gesture_required", message: "Click to open the diff") }
        prefetchDiff(link)
        let text = await diffs[link.url]?.read.value
        // The page closed (or left) while the read ran: its click opens nothing now.
        try Task.checkCancellation()
        guard let text, text.hasPrefix("diff --git ") else {
            // A failed read is not kept: the next click reads again.
            diffs[link.url] = nil
            throw PageError(code: "cmux.github.diff_unavailable", message: Self.diffUnavailable, retryable: true)
        }
        return ["opened": .bool(openDiff(text, link, file, anchor()))]
    }

    /// The link a call names, or invalid params.
    private func link(_ params: JSONValue, _ op: String) throws -> GitHubLink {
        guard let address = params["url"]?.stringValue, let url = URL(string: address), let link = GitHubLink(url) else {
            throw PageError.invalidParams("cmux.github.\(op) needs a pull request url")
        }
        return link
    }

    /// One file's part of the pull request's diff, for the page's inline expand.
    private func diffFile(_ params: JSONValue) async throws -> JSONValue {
        let link = try link(params, "diff.file")
        guard let file = params["file"]?.stringValue, !file.isEmpty, file.utf8.count <= 4096 else {
            throw PageError.invalidParams("cmux.github.diff.file needs a file")
        }
        prefetchDiff(link)
        let text = await diffs[link.url]?.read.value
        try Task.checkCancellation()
        guard let text, text.hasPrefix("diff --git ") else {
            diffs[link.url] = nil
            throw PageError(code: "cmux.github.diff_unavailable", message: Self.diffUnavailable, retryable: true)
        }
        // Detached: the diff can be 16 MB, never scanned on the main thread.
        let patch = await Task.detached(priority: .userInitiated) { Self.patch(of: file, in: text) }.value
        guard let patch else { return ["patch": .null] }
        guard patch.utf8.count <= Self.maximumInlinePatch else { return ["patch": .null, "tooLarge": .bool(true)] }
        return ["patch": .string(patch)]
    }

    /// `file`'s section of the unified diff `text` (from its `diff --git` line to the next), nil
    /// when no section names it: by its `+++ b/` or `--- a/` line (a deleted file), a rename's
    /// `rename to`, or a plain `diff --git a/<file> b/<file>` header (a mode-only or binary change).
    nonisolated static func patch(of file: String, in text: String) -> String? {
        let marker = "\ndiff --git "
        var sections: [Substring] = []
        var rest = Substring(text)
        while let range = rest.range(of: marker) {
            sections.append(rest[rest.startIndex..<rest.index(after: range.lowerBound)])
            rest = rest[rest.index(after: range.lowerBound)...]
        }
        sections.append(rest)
        let names = ["+++ b/\(file)", "--- a/\(file)", "rename to \(file)"]
        for section in sections {
            var header = true
            for line in section.split(separator: "\n", omittingEmptySubsequences: false) {
                if header, line.hasPrefix("diff --git ") {
                    if line == "diff --git a/\(file) b/\(file)" { return String(section) }
                    continue
                }
                // The hunks begin: past the header, a line is the file's text, not its name.
                if line.hasPrefix("@@") { break }
                header = false
                if names.contains(where: { line == $0 }) { return String(section) }
            }
        }
        return nil
    }

    /// The pull request's details, from the one read kept for its `updatedAt`.
    private func readDetails(_ params: JSONValue) async throws -> JSONValue {
        let link = try link(params, "pr.details")
        let updatedAt = cache.answer(link.url, read: false).pullRequest?.updatedAt ?? ""
        let now = ContinuousClock.now
        let kept = details[link.url]
        let entry: Details
        // A new updatedAt (a comment, a push) reads again at once; the same one reuses a good read, or a
        // failed one for a minute. The cache's updatedAt moves at most once a minute, so this does too.
        if let kept, kept.updatedAt == updatedAt, kept.good || now - kept.began < Self.detailsFreshness {
            entry = kept
        } else {
            let reader = detailsReader
            // task-owner: one details read per pull request and updatedAt; pr.details awaits it, a newer one replaces it.
            entry = Details(updatedAt: updatedAt, began: now, read: Task.detached(priority: .userInitiated) { await reader(link) })
            details[link.url] = entry
            while details.count > Self.maximumDiffs, let other = details.keys.first(where: { $0 != link.url }) { details[other] = nil }
        }
        let value = await entry.read.value
        try Task.checkCancellation()
        if value != nil, details[link.url]?.began == entry.began { details[link.url]?.good = true }
        return ["details": value?.json ?? .null]
    }

    /// Merges the pull request the page showed, pinned to the head it showed.
    private func merge(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let link = try link(params, "pr.merge")
        guard let head = params["head"]?.stringValue, AgentPaneGitPullRequest.isCommit(head) else {
            throw PageError.invalidParams("cmux.github.pr.merge needs the head commit the page showed")
        }
        guard spendGesture(context) else { throw PageError(code: "cmux.github.gesture_required", message: "Click to merge") }
        switch await merger(link.url.absoluteString, head) {
        case .merged(let queued):
            // What the page shows next is read again: its state, its checks, its conversation.
            details[link.url] = nil
            _ = cache.answer(link.url)
            return ["merged": .bool(true), "queued": .bool(queued)]
        case .refused(let message):
            throw PageError(code: "cmux.github.merge_refused", message: message)
        }
    }

    /// The CI dashboard's jobs at the page's head, from the App's one checks cache.
    private func readChecks(_ params: JSONValue) async throws -> JSONValue {
        let link = try link(params, "checks.read")
        let answer = await checksCache.answer(link, head: params["head"]?.stringValue ?? "")
        try Task.checkCancellation()
        return ["checks": answer.checks?.json ?? .null, "reading": .bool(answer.reading)]
    }

    /// Re-runs the failed jobs of the runs the dashboard showed failing.
    private func rerun(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let link = try link(params, "checks.rerun")
        let asked = Set((params["runs"]?.arrayValue ?? []).compactMap(\.intValue))
        let runs = asked.intersection(checksCache.failedRuns(link)).sorted()
        guard !asked.isEmpty, runs.count == asked.count else {
            throw PageError.invalidParams("cmux.github.checks.rerun names only runs the page showed failing")
        }
        guard spendGesture(context) else { throw PageError(code: "cmux.github.gesture_required", message: "Click to re-run") }
        var refusal: String?
        for run in runs {
            if let message = await rerunner(link.repository, run) { refusal = message }
        }
        checksCache.expire(link)
        if let refusal { throw PageError(code: "cmux.github.rerun_refused", message: refusal) }
        return ["rerun": JSONValue(runs.count)]
    }

    /// Spends the person's key or click in the page view (the host's record, never the page's word).
    private func spendGesture(_ context: PageCallContext) -> Bool {
        guard context.userGesture, let event = context.gestureEvent, event != spentGesture else { return false }
        spentGesture = event
        return true
    }

    /// The tab's title.
    public static var title: String { t("github.tab.title", "GitHub") }

    static var diffUnavailable: String {
        t("github.diff.unavailable", "The diff could not be read. Check that the GitHub CLI (gh) is signed in, then try again.")
    }

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "GitHubViewer", bundle: .module)
    }
}

public extension GitHubPageProvider {
    /// A pull request's Files tab (Session Info's View diff, a `/pull/N/files` link in a reply): its
    /// diff (`gh pr diff`) opens through `openDiff`, no page in between (Leo, 2026-11-05: "you want to
    /// see the diff? Boom, here's a diff"); a diff that could not be read opens the Files tab's web page.
    static func openFiles(_ link: GitHubLink, openDiff: @escaping @MainActor (String) -> Void, openWeb: @escaping @MainActor (URL) -> Void) {
        openFiles(link, read: { await AgentChatPullRequestReader().diff(url: $0) }, openDiff: openDiff, openWeb: openWeb)
    }

    /// ``openFiles(_:openDiff:openWeb:)`` with its diff read by `read` (tests).
    static func openFiles(_ link: GitHubLink, read: @escaping @Sendable (URL) async -> String?,
                          openDiff: @escaping @MainActor (String) -> Void, openWeb: @escaping @MainActor (URL) -> Void) {
        // task-owner: one gh diff read per click; it opens the diff, or the web page when the read fails.
        Task { @MainActor in
            // Detached: the read decodes up to 16 MB, never on the main thread.
            let text = await Task.detached(priority: .userInitiated) { await read(link.url) }.value
            if let text, text.hasPrefix("diff --git ") { openDiff(text) } else { openWeb(link.filesURL) }
        }
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
public extension GitHubPageProvider {
    /// `github_right`'s pull request as `gh pr view --json` prints one: a typical page of it (checks, files).
    static func benchFixture(_ url: URL) -> String {
        let number = Int(url.lastPathComponent) ?? 1
        let checks = (1...12).map { #"{"__typename":"CheckRun","name":"check \#($0)","status":"COMPLETED","conclusion":"SUCCESS"}"# }
        let files = (1...24).map { #"{"path":"Sources/Module/File\#($0).swift","additions":\#($0 * 3),"deletions":\#($0)}"# }
        return #"{"url":"\#(url.absoluteString)","number":\#(number),"title":"Bench pull request","state":"OPEN","isDraft":false,"reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[\#(checks.joined(separator: ","))],"createdAt":"2026-11-04T18:00:00Z","updatedAt":"2026-11-05T02:40:00Z","mergedAt":"","additions":900,"deletions":300,"changedFiles":24,"files":[\#(files.joined(separator: ","))],"labels":[],"baseRefName":"feat-cmux-next","headRefName":"lane/bench","author":{"login":"bench"}}"#
    }
}
#endif
