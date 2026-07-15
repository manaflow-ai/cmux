/// Sendable syntax-highlight output for one source line.
public struct HighlightedCode: Sendable, Equatable {
    /// Ordered foreground-color runs.
    public let spans: [CodeHighlightSpan]

    /// Creates highlighted output from ordered runs.
    /// - Parameter spans: Ordered foreground-color runs.
    public init(spans: [CodeHighlightSpan]) {
        self.spans = spans
    }
}
