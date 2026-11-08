/// Shared glyph and tint presentation for one artifact row or tile.
public struct ChatArtifactGalleryGlyphPresentation: Sendable, Equatable {
    /// SF Symbol rendered when an image thumbnail is unavailable or inapplicable.
    public let systemImageName: String

    /// Semantic tint applied to the symbol.
    public let tint: ChatArtifactGalleryGlyphTint

    /// Creates a shared artifact glyph presentation.
    ///
    /// - Parameters:
    ///   - systemImageName: SF Symbol rendered by list and grid consumers.
    ///   - tint: Semantic symbol tint.
    public init(systemImageName: String, tint: ChatArtifactGalleryGlyphTint) {
        self.systemImageName = systemImageName
        self.tint = tint
    }
}
