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
@MainActor
public final class GitHubPageProvider: PageProvider {
    public static let namespace = "cmux.github."

    /// A pull request's diff, read once per `updatedAt`.
    private struct Diff {
        let updatedAt: String
        let read: Task<String?, Never>
    }

    private let links: AgentPaneReplyLinks
    private let cache: AgentReplyPullRequests
    private let diffReader: @Sendable (URL) async -> String?
    private let openWeb: @MainActor (URL, NSView?) -> Bool
    private let openDiff: @MainActor (_ text: String, _ link: GitHubLink, _ file: String?, _ from: NSView?) -> Bool
    private var diffs: [URL: Diff] = [:]
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
                openWeb: @escaping @MainActor (URL, NSView?) -> Bool,
                openDiff: @escaping @MainActor (_ text: String, _ link: GitHubLink, _ file: String?, _ from: NSView?) -> Bool) {
        self.cache = cache
        self.diffReader = diffReader
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
            // A read started before the cache had the pull request is as new as its first `updatedAt`.
            if kept.updatedAt.isEmpty {
                diffs[link.url] = Diff(updatedAt: updatedAt, read: kept.read)
                return
            }
        }
        let reader = diffReader, url = link.url
        // task-owner: one gh diff read per pull request and updatedAt; diff.open awaits it, a newer updatedAt replaces it.
        // Detached: the read decodes up to 16 MB, never on the main thread.
        diffs[link.url] = Diff(updatedAt: updatedAt, read: Task.detached(priority: .userInitiated) { await reader(url) })
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
