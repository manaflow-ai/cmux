import AppKit
import CmuxNextAgentPane
import CmuxNextDaemonService
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
/// A highlight's PR chip and its hover card (the agent page's card, shared) use two more:
/// - `pr.inspect {url}`: what the host already has about a GitHub pull request, the same reply as
///   the agent page's `pr.inspect` (``AgentPanePullRequestAnswer/reply``), from the app's one cache
///   (``AgentReplyPullRequests``). Only a plain `https://github.com/<owner>/<repo>/pull/<n>`. Passive.
/// - `link.open {url}`: opens an https URL in a cmux browser tab, as a link clicked in a chat opens.
///   Spends one gesture of the person's in the page view (the host's record); anything but https
///   (http, `file:`, `javascript:`, a URL with user info) is refused.
@MainActor
final class ChangelogPageProvider: PageProvider {
    private let source: (any ChangelogSource)?
    private let currentBuild: String
    /// Inlines checked release media as `data:` URLs (the page's CSP admits no remote image).
    private let media: ReleaseMediaStore?
    /// What the app's pull request cache has for a link (``AgentReplyPullRequests/answer(_:)``).
    private let pullRequests: @MainActor (URL) -> AgentPanePullRequestAnswer
    /// Opens a checked https URL in a cmux browser tab from the page view (``anchor``); false when
    /// nothing opened.
    private let openLink: @MainActor (URL, NSView?) -> Bool
    /// The gesture the last `link.open` spent: one key or click opens one link.
    private var spentGesture: TimeInterval?
    /// The page view, so a link opens from the pane that shows it (nil: the active window's pane).
    var anchor: @MainActor () -> NSView? = { nil }

    init(source: (any ChangelogSource)?, currentBuild: String, media: ReleaseMediaStore? = nil,
         pullRequests: @escaping @MainActor (URL) -> AgentPanePullRequestAnswer = { AgentReplyPullRequests.shared.answer($0) },
         openLink: @escaping @MainActor (URL, NSView?) -> Bool = { _, _ in false }) {
        self.source = source
        self.currentBuild = currentBuild
        self.media = media
        self.pullRequests = pullRequests
        self.openLink = openLink
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
        case "cmux.changelog.pr.inspect":
            guard let url = AgentPaneReplyRequest.pullRequestURL(try Self.url(params)) else {
                throw PageError.invalidParams("url must be a GitHub pull request")
            }
            return pullRequests(url).reply
        case "cmux.changelog.link.open":
            guard let url = AgentPaneReplyRequest.webURL(try Self.url(params)), url.scheme?.lowercased() == "https" else {
                throw PageError.invalidParams("url must be an https link")
            }
            guard context.userGesture, let event = context.gestureEvent, event != spentGesture else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
            }
            spentGesture = event
            guard openLink(url, anchor()) else { throw PageError(code: "cmux.changelog.open_failed", message: url.absoluteString) }
            return .null
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// The one param of `pr.inspect` and `link.open`: `url`, a string, and no other key.
    private static func url(_ params: JSONValue) throws -> String {
        guard let members = params.objectValue, Set(members.keys) == ["url"], let url = members["url"]?.stringValue else {
            throw PageError.invalidParams("url is required, and the only param")
        }
        return url
    }

    private static func json(_ value: some Encodable) throws -> JSONValue { try JSONValue.parse(JSONEncoder().encode(value)) }
}
