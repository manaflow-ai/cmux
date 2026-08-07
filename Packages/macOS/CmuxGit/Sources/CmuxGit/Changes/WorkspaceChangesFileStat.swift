public import CmuxAgentChat
public import Foundation

/// Artifact metadata paired with a cheap filesystem revision fingerprint.
public struct WorkspaceChangesFileStat: Sendable, Equatable {
    /// Artifact-compatible metadata for the authorized file.
    public let artifactStat: ChatArtifactStat
    /// Size, timestamps, device, and inode fingerprint for the returned revision.
    public let contentFingerprint: String?

    /// The authorized file's byte size.
    public var size: Int64 { artifactStat.size }
    /// Whether the authorized path existed.
    public var exists: Bool { artifactStat.exists }
    /// Whether the authorized path is a directory.
    public var isDirectory: Bool { artifactStat.isDirectory }
    /// Last modification time reported by the filesystem.
    public var modifiedAt: Date { artifactStat.modifiedAt }
    /// Artifact preview category.
    public var kind: ChatArtifactKind { artifactStat.kind }
    /// Best-effort MIME type.
    public var mimeType: String? { artifactStat.mimeType }

    /// Creates fingerprinted workspace-change metadata.
    /// - Parameters:
    ///   - artifactStat: Artifact-compatible file metadata.
    ///   - contentFingerprint: Identity-bearing filesystem fingerprint.
    public init(
        artifactStat: ChatArtifactStat,
        contentFingerprint: String?
    ) {
        self.artifactStat = artifactStat
        self.contentFingerprint = contentFingerprint
    }
}
