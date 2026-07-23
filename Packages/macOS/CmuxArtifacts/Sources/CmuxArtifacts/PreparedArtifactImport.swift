import Foundation

/// Immutable staged candidate used by one repository batch.
struct PreparedArtifactImport {
    let candidate: ArtifactCandidate
    let snapshot: ArtifactSourceSnapshot
    let digest: String
}
