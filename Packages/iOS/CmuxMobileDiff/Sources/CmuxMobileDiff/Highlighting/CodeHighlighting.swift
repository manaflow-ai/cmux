public import Foundation

/// A replaceable seam for per-row source-code highlighting.
public protocol CodeHighlighting: Sendable {
    /// Highlights one source row in a known language.
    /// - Parameters:
    ///   - code: Source row without a diff marker.
    ///   - language: Highlight.js language identifier, or `nil` for no highlighting.
    /// - Returns: Highlighted text, or `nil` when unsupported or unavailable.
    func highlight(_ code: String, language: String?) -> AttributedString?
}
