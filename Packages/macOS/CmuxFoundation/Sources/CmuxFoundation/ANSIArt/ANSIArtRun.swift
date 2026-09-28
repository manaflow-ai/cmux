/// A span of printable ANSI art text that shares one style.
public struct ANSIArtRun: Hashable, Sendable {
    /// The printable text, with every escape and control character removed.
    public var text: String
    /// The style in effect for the whole span.
    public var style: ANSIArtStyle

    /// Creates a run.
    ///
    /// - Parameters:
    ///   - text: The printable text.
    ///   - style: The style for all of `text`.
    public init(text: String, style: ANSIArtStyle) {
        self.text = text
        self.style = style
    }
}
