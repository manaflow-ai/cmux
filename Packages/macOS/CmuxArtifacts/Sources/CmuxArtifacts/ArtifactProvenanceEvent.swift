import Foundation

/// One capture occurrence retained in content-addressed metadata.
struct ArtifactProvenanceEvent: Codable, Equatable, Sendable {
    let sourcePath: String
    let workspaceID: String?
    let sessionID: String?
    let provenance: ArtifactProvenance
    let capturedAt: Date
}
