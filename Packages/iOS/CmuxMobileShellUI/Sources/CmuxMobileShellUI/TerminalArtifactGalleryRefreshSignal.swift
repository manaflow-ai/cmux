/// One generation-checked artifact count accepted by the terminal chip pipeline.
struct TerminalArtifactGalleryRefreshSignal: Sendable, Equatable {
    let count: Int
    let surfaceGeneration: UInt64

    static let initial = TerminalArtifactGalleryRefreshSignal(count: 0, surfaceGeneration: 0)
}
