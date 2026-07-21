public import Foundation

/// Provenance returned for one imported or deduplicated artifact.
public struct ArtifactRecord: Codable, Equatable, Sendable {
    /// SHA-256 content digest used for deduplication.
    public let digest: String
    /// Original absolute source path at capture time.
    public let sourcePath: String
    /// Current artifact path relative to `.cmux/artifacts` at capture time.
    public let relativePath: String
    /// Workspace identity attached to the capture.
    public let workspaceID: String?
    /// Agent session identity attached to the capture.
    public let sessionID: String?
    /// Detection or manual provenance.
    public let provenance: ArtifactProvenance
    /// Capture timestamp.
    public let capturedAt: Date
    /// File size in bytes.
    public let size: Int64

    /// Creates recorded artifact provenance.
    ///
    /// - Parameters:
    ///   - digest: SHA-256 content digest.
    ///   - sourcePath: Original absolute source path.
    ///   - relativePath: Artifact-root-relative path at capture time.
    ///   - workspaceID: Associated workspace identity.
    ///   - sessionID: Associated agent-session identity.
    ///   - provenance: How cmux learned about the file.
    ///   - capturedAt: Capture timestamp.
    ///   - size: File size in bytes.
    public init(
        digest: String,
        sourcePath: String,
        relativePath: String,
        workspaceID: String?,
        sessionID: String?,
        provenance: ArtifactProvenance,
        capturedAt: Date,
        size: Int64
    ) {
        self.digest = digest
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.provenance = provenance
        self.capturedAt = capturedAt
        self.size = size
    }
}
