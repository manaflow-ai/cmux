import CmuxMobileMarkdown
import CoreGraphics
import Foundation

/// A long markdown paragraph as several transcript rows of a few lines each, drawn one under the
/// other with the paragraph's own line spacing (`ChatInlineText`'s 5 pt), so they read as the one
/// paragraph. One row tens of thousands of points tall (a pasted 240-line log) is past what a
/// layer draws in one piece, and the transcript's list reset under the reader as it reached it;
/// short rows also draw only what is on screen. Every transcript list builds its rows here
/// (`ChatTranscriptBuilder`): the agent chat and a subagent's transcript alike.
enum ChatParagraphParts {
    /// Paragraphs up to this many lines stay one row.
    static let maxLines = 24
    /// The space between two parts: the paragraph's line spacing.
    static let lineGap: Double = 5

    /// `block`'s parts: itself unless it is a paragraph over `maxLines` lines. A part ends at a
    /// line end where its inline marks close; with none within `2 * maxLines` lines it ends there
    /// anyway, closing what is open (a code span, emphasis) and opening it again at the next
    /// part's start, so a long paragraph always splits.
    static func split(_ block: MarkdownBlock) -> [MarkdownBlock] {
        guard case .paragraph(let text) = block.kind else { return [block] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines, !MarkdownDocument(blocks: [block]).needsWebRenderer else { return [block] }
        var parts: [MarkdownBlock] = []
        var start = 0
        var line = 0
        var carried = Marks()
        while line < lines.count {
            line += 1
            let size = line - start
            guard size >= maxLines || line == lines.count else { continue }
            let marks = carried.after(lines[start..<line])
            // A part ends where its marks close, or at twice the size with what is open carried.
            guard line == lines.count || marks.isEmpty || size >= 2 * maxLines else { continue }
            let body = lines[start..<line].joined(separator: "\n")
            let text = carried.opening + body + (line == lines.count ? "" : marks.closing)
            parts.append(MarkdownBlock(id: block.id, kind: .paragraph(text)))
            carried = line == lines.count ? Marks() : marks
            start = line
        }
        return parts.count > 1 ? parts : [block]
    }

    /// The inline marks open at a point of a paragraph: a code span, and emphasis by `*` or
    /// `**` (outside code). Brackets are not tracked: a `[` without `](` draws as itself.
    struct Marks: Equatable {
        var code = false
        var strong = false
        var emphasis = false

        var isEmpty: Bool { !code && !strong && !emphasis }
        /// What closes them at a part's end (code first: a star inside a code span is text).
        var closing: String { (code ? "`" : "") + (emphasis ? "*" : "") + (strong ? "**" : "") }
        /// What opens them again at the next part's start, in the reverse order.
        var opening: String { (strong ? "**" : "") + (emphasis ? "*" : "") + (code ? "`" : "") }

        /// The marks open after `lines`, these being open before them. A run of stars outside a
        /// code span toggles strong for each pair and emphasis for an odd one left.
        func after(_ lines: ArraySlice<Substring>) -> Marks {
            var marks = self
            for line in lines {
                var run = 0
                func flush() {
                    if run > 0, !marks.code {
                        if (run / 2) % 2 == 1 { marks.strong.toggle() }
                        if run % 2 == 1 { marks.emphasis.toggle() }
                    }
                    run = 0
                }
                for character in line {
                    if character == "*" { run += 1; continue }
                    flush()
                    if character == "`" { marks.code.toggle() }
                }
                flush()
            }
            return marks
        }
    }

    /// Which part holds character `offset` of the paragraph, and the offset within it. The parts
    /// rejoin with a newline between them (`split`), so part `k` starts after the lengths before
    /// it and one newline each.
    static func locate(offset: Int, partLengths: [Int]) -> (part: Int, offset: Int) {
        var start = 0
        for (index, length) in partLengths.enumerated() {
            if offset < start + length + 1 || index == partLengths.count - 1 {
                return (index, max(0, min(offset - start, length)))
            }
            start += length + 1
        }
        return (0, 0)
    }
}
