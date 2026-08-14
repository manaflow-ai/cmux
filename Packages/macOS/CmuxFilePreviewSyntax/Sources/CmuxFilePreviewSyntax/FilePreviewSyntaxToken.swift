/// A highlighted source span expressed in UTF-16 offsets for direct TextKit conversion.
public struct FilePreviewSyntaxToken: Equatable, Sendable {
    /// The half-open UTF-16 range occupied by the token.
    public let utf16Range: Range<Int>

    /// The display classification assigned to the token.
    public let kind: FilePreviewSyntaxTokenKind

    /// Creates a highlighted source span.
    ///
    /// - Parameters:
    ///   - utf16Range: Half-open UTF-16 offsets into the original source.
    ///   - kind: Display classification for the span.
    public init(
        utf16Range: Range<Int>,
        kind: FilePreviewSyntaxTokenKind
    ) {
        self.utf16Range = utf16Range
        self.kind = kind
    }
}
