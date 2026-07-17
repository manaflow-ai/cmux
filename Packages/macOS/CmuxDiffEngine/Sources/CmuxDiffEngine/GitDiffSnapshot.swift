/// A fully batched working-tree snapshot against one resolved baseline.
struct GitDiffSnapshot: Sendable, Equatable {
    let base: ResolvedDiffBase
    let files: [GitDiffFile]
}
