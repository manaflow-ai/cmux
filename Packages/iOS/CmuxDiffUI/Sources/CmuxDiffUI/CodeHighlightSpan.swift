/// One foreground-color run produced by syntax highlighting.
public struct CodeHighlightSpan: Sendable, Equatable {
    /// Text covered by this run.
    public let text: String
    /// Highlighted foreground color, or `nil` for the view's primary color.
    public let foreground: CodeHighlightColor?

    /// Creates a syntax-highlight run.
    /// - Parameters:
    ///   - text: Text covered by the run.
    ///   - foreground: Optional syntax foreground color.
    public init(text: String, foreground: CodeHighlightColor?) {
        self.text = text
        self.foreground = foreground
    }
}
