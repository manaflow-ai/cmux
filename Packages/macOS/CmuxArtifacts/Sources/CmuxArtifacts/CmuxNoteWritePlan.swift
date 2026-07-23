import Foundation

/// Immutable Note mutation plan validated before entering the filesystem write phase.
struct CmuxNoteWritePlan: Sendable {
    let contentDirectory: URL
    let destination: URL
    let existing: CmuxProjectNote?

    var privacyDestinations: [URL] {
        guard existing == nil else { return [destination] }
        let sessionDirectory = contentDirectory.deletingLastPathComponent()
        return [
            destination,
            sessionDirectory.appendingPathComponent(ArtifactPathResolver.sessionMarkerName),
            sessionDirectory.appendingPathComponent(ArtifactPathResolver.workspaceMarkerName),
        ]
    }
}
