import Foundation

/// Size and line-count gates for the v1 Highlightr engine.
///
/// File Preview can load up to 16 MB. Full-document JavaScriptCore highlighting
/// on that payload multiplies memory and fights the TextKit 1 selection path
/// (`manaflow-ai/cmux#4576`). Token coloring is skipped above these ceilings;
/// editor chrome (gutter, current line, indent guides) still runs.
public struct HighlightPolicy: Sendable {
    /// kb:ceiling: Skip Highlightr when the UTF-8 payload exceeds 256 KiB.
    public static let maximumHighlightedBytes = 256 * 1024

    /// kb:ceiling: Skip Highlightr when the line count exceeds 4_000 even if
    /// the byte size is still under ``maximumHighlightedBytes``.
    public static let maximumHighlightedLines = 4_000

    /// Creates a policy with the default ceilings.
    public init() {}

    /// Counts lines as one plus the number of `\n` bytes.
    ///
    /// Scans UTF-8 code units, not `Character` grapheme clusters: a newline
    /// is a single-byte ASCII `0x0A`, so grapheme decoding adds cost without
    /// changing the count.
    public func lineCount(in content: String) -> Int {
        var lines = 1
        for byte in content.utf8 where byte == 0x0A {
            lines += 1
        }
        return lines
    }

    /// Returns whether `content` should be token-colored for `language`.
    public func shouldHighlight(content: String, language: String?) -> Bool {
        guard language != nil, !content.isEmpty else { return false }
        guard content.utf8.count <= Self.maximumHighlightedBytes else { return false }

        var lines = 1
        for byte in content.utf8 {
            if byte == 0x0A {
                lines += 1
                guard lines <= Self.maximumHighlightedLines else { return false }
            }
        }
        return true
    }

    /// Returns whether a buffer of `utf8Count` bytes and `lineCount` lines
    /// should be token-colored as `language`.
    ///
    /// - Parameters:
    ///   - utf8Count: UTF-8 byte length of the buffer.
    ///   - lineCount: Line count of the buffer.
    ///   - language: highlight.js language id, or `nil` when unknown.
    /// - Returns: `false` when language is missing, the buffer is empty, or a ceiling is exceeded.
    public func shouldHighlight(utf8Count: Int, lineCount: Int, language: String?) -> Bool {
        guard language != nil else { return false }
        guard utf8Count > 0 else { return false }
        // kb:ceiling: maximumHighlightedBytes
        guard utf8Count <= Self.maximumHighlightedBytes else { return false }
        // kb:ceiling: maximumHighlightedLines
        guard lineCount > 0, lineCount <= Self.maximumHighlightedLines else { return false }
        return true
    }
}
