/// Git workspace metadata plus whether its pre-stamped repository authority is
/// still current after the tracked scan completes.
public nonisolated struct GitWorkspaceMetadataSnapshot: Equatable, Sendable {
    /// Parsed repository metadata.
    public let metadata: GitWorkspaceMetadata
    /// `false` when a watcher advanced repository revision during the scan.
    public let isCurrent: Bool

    /// Creates an authority-stamped metadata result.
    public init(metadata: GitWorkspaceMetadata, isCurrent: Bool) {
        self.metadata = metadata
        self.isCurrent = isCurrent
    }
}
