import Foundation

/// Splits agent prose into text runs and fenced code blocks.
///
/// Prose bubbles render text runs as markdown and code runs as embedded
/// monospace blocks (product rule: code blocks read as screens, not as
/// bubble text). Pure and synchronous for testability.
public struct ChatProseSegmenter: Sendable {
    /// Creates a segmenter.
    public init() {}

    /// Splits `text` on triple-backtick fences.
    ///
    /// An unterminated fence swallows the rest of the message as code
    /// (streaming-friendly: a fence being typed still renders as code).
    ///
    /// - Parameter text: The message text.
    /// - Returns: Segments in display order; never empty for non-empty
    ///   input.
    public func segments(from text: String) -> [ChatProseSegment] {
        var segments: [ChatProseSegment] = []
        var currentText: [Substring] = []
        var codeLanguage: String?
        var codeLines: [Substring] = []
        var inCode = false

        func flushText() {
            let joined = currentText.joined(separator: "\n")
            currentText = []
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            segments.append(ChatProseSegment(index: segments.count, kind: .text, content: trimmed))
        }

        func flushCode() {
            let joined = codeLines.joined(separator: "\n")
            codeLines = []
            segments.append(
                ChatProseSegment(
                    index: segments.count,
                    kind: .code(language: codeLanguage),
                    content: joined
                )
            )
            codeLanguage = nil
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("```") {
                if inCode {
                    inCode = false
                    flushCode()
                } else {
                    inCode = true
                    flushText()
                    let language = stripped.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                }
                continue
            }
            if inCode {
                codeLines.append(line)
            } else {
                currentText.append(line)
            }
        }
        if inCode {
            flushCode()
        } else {
            flushText()
        }
        return segments
    }
}
