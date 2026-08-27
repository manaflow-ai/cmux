import Foundation

/// Builds the simple unified-ish diffs shown on ``ChatFileEdit`` cards.
///
/// Transcripts carry whole old/new strings rather than diffs, so this
/// renders removals as `-` lines followed by additions as `+` lines and
/// counts lines on each side. It is presentation-grade, not patch-grade.
struct TranscriptDiffBuilder: Sendable {
    /// A rendered change: the diff text plus line counts.
    struct Change: Sendable, Equatable {
        /// The rendered `-`/`+` line diff.
        let diff: String
        /// Count of added lines.
        let additions: Int
        /// Count of removed lines.
        let deletions: Int
    }

    /// Creates a diff builder.
    init() {}

    /// Renders an in-place replacement of `oldText` by `newText`.
    ///
    /// - Parameters:
    ///   - oldText: The replaced text (empty for pure insertions).
    ///   - newText: The replacement text (empty for pure removals).
    /// - Returns: The rendered change with line counts.
    func replacement(oldText: String, newText: String) -> Change {
        let oldLines = lines(oldText)
        let newLines = lines(newText)
        let rendered = (oldLines.map { "-" + $0 } + newLines.map { "+" + $0 })
            .joined(separator: "\n")
        return Change(diff: rendered, additions: newLines.count, deletions: oldLines.count)
    }

    /// Renders a whole-file write as pure additions.
    ///
    /// - Parameter content: The written file content.
    /// - Returns: The rendered change with the addition count.
    func creation(content: String) -> Change {
        let newLines = lines(content)
        let rendered = newLines.map { "+" + $0 }.joined(separator: "\n")
        return Change(diff: rendered, additions: newLines.count, deletions: 0)
    }

    /// Combines several changes into one (for multi-edit tools).
    ///
    /// - Parameter changes: The per-edit changes, in order.
    /// - Returns: One change with concatenated diff and summed counts.
    func combined(_ changes: [Change]) -> Change {
        Change(
            diff: changes.map(\.diff).joined(separator: "\n"),
            additions: changes.reduce(0) { $0 + $1.additions },
            deletions: changes.reduce(0) { $0 + $1.deletions }
        )
    }

    /// Splits text into lines, treating empty text as zero lines.
    ///
    /// - Parameter text: The text to split.
    /// - Returns: The component lines.
    private func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }
}
