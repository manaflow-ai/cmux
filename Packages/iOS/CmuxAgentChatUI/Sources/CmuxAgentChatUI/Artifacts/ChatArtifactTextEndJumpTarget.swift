/// Semantic destination for the artifact viewer's trailing-edge jump.
enum ChatArtifactTextEndJumpTarget: Equatable, Sendable {
    /// Most recently loaded text while content is still streaming.
    case latest
    /// Final document end after EOF is known.
    case end

    init(reachedEOF: Bool) {
        self = reachedEOF ? .end : .latest
    }
}
