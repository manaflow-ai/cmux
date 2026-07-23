public import Foundation

/// Identifies the filesystem revision represented by an artifact sidebar preview.
public struct ArtifactSidebarFileRevision: Hashable, Sendable {
    /// Canonical file URL represented by the preview.
    public let fileURL: URL
    /// Filesystem modification time observed by the artifact store.
    public let modifiedAt: Date?

    /// Creates an immutable preview revision.
    ///
    /// - Parameters:
    ///   - fileURL: Canonical file URL represented by the preview.
    ///   - modifiedAt: Filesystem modification time observed by the artifact store.
    public init(fileURL: URL, modifiedAt: Date?) {
        self.fileURL = fileURL
        self.modifiedAt = modifiedAt
    }
}
