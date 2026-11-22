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

    /// `block`'s parts: itself unless it is a paragraph over `maxLines` lines whose lines split
    /// with every inline mark closed in each part (else it stays whole).
    static func split(_ block: MarkdownBlock) -> [MarkdownBlock] {
        guard case .paragraph(let text) = block.kind else { return [block] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines, !MarkdownDocument(blocks: [block]).needsWebRenderer else { return [block] }
        var parts: [MarkdownBlock] = []
        var start = 0
        var line = 0
        while line < lines.count {
            line += 1
            guard line - start >= maxLines || line == lines.count else { continue }
            // A part ends only where its lines close their marks (else it takes the next line).
            guard line == lines.count || closes(lines[start..<line]) else { continue }
            parts.append(MarkdownBlock(id: block.id, kind: .paragraph(lines[start..<line].joined(separator: "\n"))))
            start = line
        }
        return parts.count > 1 ? parts : [block]
    }

    /// The lines close every inline mark they open: code spans, emphasis, links.
    static func closes(_ lines: ArraySlice<Substring>) -> Bool {
        var ticks = 0, stars = 0, unders = 0, open = 0, shut = 0
        for line in lines {
            for character in line {
                switch character {
                case "`": ticks += 1
                case "*": stars += 1
                case "_": unders += 1
                case "[": open += 1
                case "]": shut += 1
                default: break
                }
            }
        }
        return ticks % 2 == 0 && stars % 2 == 0 && unders % 2 == 0 && open == shut
    }
}
