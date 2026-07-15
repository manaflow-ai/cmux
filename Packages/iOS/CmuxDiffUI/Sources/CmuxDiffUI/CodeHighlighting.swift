/// Asynchronously converts one source line into sendable syntax-color runs.
public protocol CodeHighlighting: Sendable {
    /// Highlights one line without blocking the main actor.
    /// - Parameters:
    ///   - line: Plain source text.
    ///   - language: Highlight.js language identifier, when known.
    ///   - colorScheme: Appearance whose GitHub theme should be used.
    /// - Returns: Highlighted runs, or `nil` when highlighting is unavailable.
    func highlight(
        line: String,
        language: String?,
        colorScheme: DiffColorScheme
    ) async -> HighlightedCode?
}
