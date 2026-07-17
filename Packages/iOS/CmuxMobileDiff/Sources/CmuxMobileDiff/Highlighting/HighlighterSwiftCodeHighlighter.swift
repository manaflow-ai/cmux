public import Foundation
internal import Highlighter

/// Stateless HighlighterSwift adapter configured for one GitHub color theme.
public final class HighlighterSwiftCodeHighlighter: CodeHighlighting, Sendable {
    private let themeName: String

    /// Creates an adapter for a HighlighterSwift theme.
    /// - Parameter themeName: Bundled theme name such as `github` or `github-dark`.
    public init(themeName: String) {
        self.themeName = themeName
    }

    /// Highlights one row using a fresh, task-local JavaScript context.
    /// - Parameters:
    ///   - code: Source row without a diff marker.
    ///   - language: Highlight.js identifier, or `nil` to leave the row plain.
    /// - Returns: Foreground-only highlighted text, or `nil` when unavailable.
    public func highlight(_ code: String, language: String?) -> AttributedString? {
        guard let language, let highlighter = Highlighter() else { return nil }
        highlighter.setTheme(themeName, withFont: "Menlo-Regular", ofSize: 12)
        guard let result = highlighter.highlight(code, as: language) else { return nil }
        let foregroundOnly = NSMutableAttributedString(attributedString: result)
        foregroundOnly.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: foregroundOnly.length))
        return AttributedString(foregroundOnly)
    }
}
