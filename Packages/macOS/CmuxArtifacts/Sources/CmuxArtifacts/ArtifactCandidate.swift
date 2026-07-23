public import Foundation

/// A detected filesystem path that may be eligible for automatic capture.
public struct ArtifactCandidate: Equatable, Sendable {
    /// Source file on the local filesystem.
    public let sourceURL: URL
    /// Detection provenance used by automatic-capture policy.
    public let provenance: ArtifactProvenance

    /// Creates a detected artifact candidate.
    ///
    /// - Parameters:
    ///   - sourceURL: Source file on the local filesystem.
    ///   - provenance: How the artifact pipeline found the path.
    public init(sourceURL: URL, provenance: ArtifactProvenance) {
        self.sourceURL = sourceURL
        self.provenance = provenance
    }
}
