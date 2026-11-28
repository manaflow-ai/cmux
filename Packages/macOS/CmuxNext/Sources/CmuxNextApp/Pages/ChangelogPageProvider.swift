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

/// The owner side of the changelog page (`cmux.changelog.*`, R114), read only:
/// `list` (recent builds, newest first, and the running build) and `get {build}`
/// (one build's verified notes). A highlight's action survives only when it is
/// in ``PageDescriptor/changelogTryItActions``. Media arrive inlined (``ReleaseMediaStore``).
@MainActor
final class ChangelogPageProvider: PageProvider {
    private let source: (any ChangelogSource)?
    private let currentBuild: String
    /// Inlines checked release media as `data:` URLs (the page's CSP admits no remote image).
    private let media: ReleaseMediaStore?

    init(source: (any ChangelogSource)?, currentBuild: String, media: ReleaseMediaStore? = nil) {
        self.source = source
        self.currentBuild = currentBuild
        self.media = media
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.changelog.list":
            let builds = await source?.index() ?? []
            return ["current": .string(currentBuild), "builds": try Self.json(builds)]
        case "cmux.changelog.get":
            guard let build = params["build"]?.stringValue, !build.isEmpty else { throw PageError.invalidParams("build is required") }
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
            throw PageError.unknownOp(op)
        }
    }

    private static func json(_ value: some Encodable) throws -> JSONValue {
        try JSONValue.parse(JSONEncoder().encode(value))
    }
}
