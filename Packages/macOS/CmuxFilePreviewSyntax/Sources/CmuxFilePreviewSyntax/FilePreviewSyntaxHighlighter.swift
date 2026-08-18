/// A dependency-free, best-effort scanner for standalone source-file previews.
public struct FilePreviewSyntaxHighlighter: Sendable {
    private let grammarCatalog = FilePreviewSyntaxGrammarCatalog()

    /// Creates a syntax highlighter.
    public init() {}

    /// Scans `source` synchronously and returns TextKit-compatible UTF-16 spans.
    ///
    /// The scan exits as soon as it would exceed `maximumTokenCount`. In that case the result
    /// contains no tokens so callers can degrade to plain text without retaining partial colors.
    ///
    /// - Parameters:
    ///   - source: Source text to classify.
    ///   - language: Language family used to select scanner rules.
    ///   - maximumTokenCount: Maximum number of colored spans to emit.
    /// - Returns: The bounded scan result.
    public func highlight(
        _ source: String,
        language: FilePreviewSyntaxLanguage,
        maximumTokenCount: Int
    ) -> FilePreviewSyntaxHighlightResult {
        let grammar = grammarCatalog.grammar(for: language)
        var scanner = FilePreviewSyntaxScanner(
            source: source,
            grammar: grammar,
            maximumTokenCount: max(0, maximumTokenCount)
        )
        return scanner.scan()
    }

    /// Scans `source` on the concurrent executor.
    ///
    /// Callers should prefer this entry point from UI code and cancel their owning task when a
    /// newer editor revision supersedes the work.
    @concurrent
    public func highlightOffMain(
        _ source: String,
        language: FilePreviewSyntaxLanguage,
        maximumTokenCount: Int
    ) async -> FilePreviewSyntaxHighlightResult {
        highlight(source, language: language, maximumTokenCount: maximumTokenCount)
    }
}
