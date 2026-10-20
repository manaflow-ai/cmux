public import CmuxAgentChat
public import Foundation

/// One artifact-compatible byte chunk paired with its filesystem revision.
public struct WorkspaceChangesFileChunk: Sendable, Equatable {
    /// Artifact-compatible byte chunk.
    public let artifactChunk: ChatArtifactChunk
    /// Size, timestamps, device, and inode fingerprint for the returned revision.
    public let contentFingerprint: String?

    /// Raw bytes in this chunk.
    public var data: Data { artifactChunk.data }
    /// Byte offset where this chunk begins.
    public var offset: Int64 { artifactChunk.offset }
    /// Total file size reported by the opened file descriptor.
    public var totalSize: Int64 { artifactChunk.totalSize }
    /// Whether this chunk reaches the end of the file.
    public var eof: Bool { artifactChunk.eof }

    /// Creates a fingerprinted workspace-change byte chunk.
    /// - Parameters:
    ///   - artifactChunk: Artifact-compatible byte chunk.
    ///   - contentFingerprint: Identity-bearing filesystem fingerprint.
    public init(
        artifactChunk: ChatArtifactChunk,
        contentFingerprint: String?
    ) {
        self.artifactChunk = artifactChunk
        self.contentFingerprint = contentFingerprint
    }
}
