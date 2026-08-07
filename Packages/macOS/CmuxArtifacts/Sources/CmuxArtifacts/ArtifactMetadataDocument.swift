import Foundation

/// Content-addressed provenance that survives ordinary artifact moves.
struct ArtifactMetadataDocument: Codable, Equatable, Sendable {
    let version: Int
    let digest: String
    var lastKnownRelativePath: String
    let size: Int64
    var events: [ArtifactProvenanceEvent]
}
