public import Foundation

/// A detected filesystem path that may be eligible for automatic capture.
public struct ArtifactCandidate: Equatable, Sendable {
    /// Source file on the local filesystem.
    public let sourceURL: URL
    /// Detection provenance used by automatic-capture policy.
    public let provenance: ArtifactProvenance
    /// Canonical path authorized before an explicit save, when one exists.
    public let expectedCanonicalPath: String?
    /// Device/inode authorized before an explicit save, when one exists.
    public let expectedIdentity: ArtifactFileIdentity?

    /// Creates a detected artifact candidate.
    ///
    /// - Parameters:
    ///   - sourceURL: Source file on the local filesystem.
    ///   - provenance: How the artifact pipeline found the path.
    ///   - expectedCanonicalPath: Previously authorized canonical identity.
    ///   - expectedIdentity: Previously authorized device/inode identity.
    public init(
        sourceURL: URL,
        provenance: ArtifactProvenance,
        expectedCanonicalPath: String? = nil,
        expectedIdentity: ArtifactFileIdentity? = nil
    ) {
        self.sourceURL = sourceURL
        self.provenance = provenance
        self.expectedCanonicalPath = expectedCanonicalPath
        self.expectedIdentity = expectedIdentity
    }
}
