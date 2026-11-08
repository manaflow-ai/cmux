/// Produces token-colored attributed text for a source buffer.
///
/// Implementations must be safe to call off the main actor. v1 is
/// ``HighlightrSyntaxEngine``; a later Tree-sitter engine can conform without
/// changing File Preview chrome.
public protocol SyntaxHighlightingEngine: Sendable {
    /// Highlights `text` as `language` using `theme`.
    ///
    /// - Returns: Token-colored text, or `nil` when the policy rejects the
    ///   buffer or the engine cannot produce a result.
    func highlight(
        text: String,
        language: String?,
        theme: TokenTheme
    ) async -> HighlightedText?
}
