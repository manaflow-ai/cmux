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
/// in ``PageDescriptor/changelogTryItActions``.
@MainActor
final class ChangelogPageProvider: PageProvider {
    private let source: (any ChangelogSource)?
    private let currentBuild: String

    init(source: (any ChangelogSource)?, currentBuild: String) {
        self.source = source
        self.currentBuild = currentBuild
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        throw PageError.unknownOp(op)
    }
}
