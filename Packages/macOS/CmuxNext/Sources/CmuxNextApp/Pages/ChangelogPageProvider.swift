import AppKit
import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import CmuxNextUpdater
import Foundation

/// Where the changelog page reads verified notes (``ReleaseNotesStore`` in the app).
protocol ChangelogSource: Sendable {
    func index() async -> [ReleaseNotesIndexEntry]
    func notes(for build: String) async -> ReleaseNotes?
}

extension ReleaseNotesStore: ChangelogSource {}

/// The owner side of the changelog page (`cmux.changelog.*`, R114): `list` (recent builds,
/// newest first, and the running build), `get {build}` (one build's verified notes) and
/// `reel {build}` (`url`: its nightly reel, else null). A highlight's action survives only when it
/// is in ``PageDescriptor/changelogTryItActions``. Media arrive inlined (``ReleaseMediaStore``).
///
/// A highlight's PR chip shows the agent page's link hover card, and the card's calls come here as
/// `cmux.changelog.<method>` for its three methods (``AgentPaneReplyLinks/cardMethods``), with the
/// agent page's params, checks and replies: they run through the same ``AgentPaneReplyLinks``.
/// - `pr.inspect {url}`: what the app's pull request cache (``AgentReplyPullRequests``) has. Passive.
/// - `browser.list {}`: the installed browsers, by opaque id. Passive.
/// - `browser.openIn {url, browserId}`: opens the link in a cmux browser tab (`cmux`) or in a listed
///   browser. Only https here (the notes link GitHub), and it spends one gesture of the person's in
///   the page view (the host's record): page script cannot open a link by itself.
@MainActor
final class ChangelogPageProvider: PageProvider {
    private let source: (any ChangelogSource)?
    private let currentBuild: String
    /// Inlines checked release media as `data:` URLs (the page's CSP admits no remote image).
    private let media: ReleaseMediaStore?
    /// The agent page's link card requests (``AgentPaneReplyLinks/respond(toCard:consumeGesture:openInCmux:)``).
    private let links: AgentPaneReplyLinks
    /// Opens a checked https URL in a cmux browser tab from the page view (``anchor``); false when
    /// nothing opened.
    private let openLink: @MainActor (URL, NSView?) -> Bool
    /// The gesture the last `browser.openIn` spent: one key or click opens one link.
    private var spentGesture: TimeInterval?
    /// The page view, so a link opens from the pane that shows it (nil: the active window's pane).
    var anchor: @MainActor () -> NSView? = { nil }

    init(source: (any ChangelogSource)?, currentBuild: String, media: ReleaseMediaStore? = nil,
         links: AgentPaneReplyLinks = ChangelogPageProvider.cardLinks(),
         openLink: @escaping @MainActor (URL, NSView?) -> Bool = { _, _ in false }) {
        self.source = source
        self.currentBuild = currentBuild
        self.media = media
        self.links = links
        self.openLink = openLink
    }

    /// The card's links for the app: pull requests from the app's one cache, the installed browsers.
    static func cardLinks() -> AgentPaneReplyLinks {
        let links = AgentPaneReplyLinks()
        links.pullRequest = { AgentReplyPullRequests.shared.answer($0) }
        links.cachedPullRequest = { AgentReplyPullRequests.shared.answer($0, read: false) }
        return links
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.changelog.list":
            let builds = await source?.index() ?? []
            return ["current": .string(currentBuild), "builds": try Self.json(builds)]
        case "cmux.changelog.get", "cmux.changelog.reel":
            guard let build = params["build"]?.stringValue, !build.isEmpty else { throw PageError.invalidParams("build is required") }
            if op == "cmux.changelog.reel" { return ["url": (await media?.reel(build: build)).map { JSONValue.string($0.absoluteString) } ?? .null] }
            guard var notes = await source?.notes(for: build) else {
                throw PageError(code: "cmux.changelog.not_found", message: "No verified notes for this build", retryable: true)
            }
            if let media { notes = await media.inlined(notes) }
            notes.highlights = notes.highlights.map { highlight in
                var highlight = highlight
                if let action = highlight.action, !PageDescriptor.changelogTryItActions.contains(action.id) { highlight.action = nil }
                return highlight
            }
            return try Self.json(notes)
        default:
            let method = String(op.dropFirst(Self.namespace.count))
            guard op.hasPrefix(Self.namespace), AgentPaneReplyLinks.cardMethods.contains(method) else { throw PageError.unknownOp(op) }
            return try card(method, op: op, params: params, context: context)
        }
    }

    private static let namespace = "cmux.changelog."

    /// One link card call, parsed and answered as the agent page does; `browser.openIn` takes only https.
    private func card(_ method: String, op: String, params: JSONValue, context: PageCallContext) throws -> JSONValue {
        guard let request = AgentPaneReplyRequest(method: method, params: params.foundationObject as? [String: Any]) else {
            throw PageError.invalidParams(op)
        }
        if case .openIn(let url, _) = request, url.scheme?.lowercased() != "https" {
            throw PageError.invalidParams("\(op) opens only https links")
        }
        let reply = links.respond(toCard: request, consumeGesture: { spendGesture(context) },
                                  openInCmux: { [anchor, openLink] url in openLink(url, anchor()) })
        return try AgentPageProvider.value(of: reply)
    }

    /// Spends the person's key or click in the page view (the host's record, never the page's word):
    /// true once per gesture.
    private func spendGesture(_ context: PageCallContext) -> Bool {
        guard context.userGesture, let event = context.gestureEvent, event != spentGesture else { return false }
        spentGesture = event
        return true
    }

    private static func json(_ value: some Encodable) throws -> JSONValue { try JSONValue.parse(JSONEncoder().encode(value)) }
}
