#if os(iOS)
struct ChatArtifactViewerActionsMenuValue: Equatable, Sendable {
    let snapshot: ChatArtifactViewerPageSnapshot
    let loaderScope: ChatArtifactLoaderScope
    let loaderSupportsArtifacts: Bool
    let loaderSupportsDirectoryBrowsing: Bool
}
#endif
