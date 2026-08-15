import Foundation

/// A single rendered line of a unified diff.
struct GitDiffRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `+++` / `---` file header lines and the `diff --git` file header.
        case header
        /// A `@@ ... @@` hunk header.
        case hunk
        /// An added line (leading `+`).
        case addition
        /// A deleted line (leading `-`).
        case deletion
        /// A context line (leading space or blank).
        case context
        /// `\ No newline at end of file`.
        case noNewline
    }

    let id: Int
    let kind: Kind
    let text: String
}

/// Classifies a unified-diff string into immutable render rows.
///
/// Pure and app-independent so it is directly unit-testable. The leading
/// `+`/`-`/space marker is preserved in ``GitDiffRow/text``; only the kind
/// changes, so coloring is driven entirely by ``GitDiffRow/kind``.
enum GitDiffParser {
    /// Splits `unifiedDiff` on newlines and classifies each line.
    ///
    /// Order of classification: a line beginning `\ No newline` is
    /// ``GitDiffRow/Kind/noNewline``; `+++`/`---` and the leading `diff --git`
    /// file header are ``GitDiffRow/Kind/header``; `@@` is
    /// ``GitDiffRow/Kind/hunk``; a leading `+` is an
    /// ``GitDiffRow/Kind/addition``; a leading `-` is a
    /// ``GitDiffRow/Kind/deletion``; anything else is
    /// ``GitDiffRow/Kind/context``. Row ids are the zero-based line index.
    ///
    /// - Parameter unifiedDiff: Raw unified-diff output.
    /// - Returns: One row per input line, in order.
    static func parse(_ unifiedDiff: String) -> [GitDiffRow] {
        var lines = unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false)
        // A trailing newline is a line terminator, not an extra blank line.
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        // A diff containing only terminators has no content rows.
        guard lines.contains(where: { !$0.isEmpty }) else { return [] }
        return lines.enumerated().map { index, line in
            let text = String(line)
            return GitDiffRow(id: index, kind: Self.kind(of: text), text: text)
        }
    }

    private static func kind(of line: String) -> GitDiffRow.Kind {
        if line.hasPrefix("\\ No newline") {
            return .noNewline
        }
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git ") {
            return .header
        }
        if line.hasPrefix("@@") {
            return .hunk
        }
        if line.hasPrefix("+") {
            return .addition
        }
        if line.hasPrefix("-") {
            return .deletion
        }
        return .context
    }
}
