internal import Foundation

/// Immutable content for one side of a split diff row.
struct DiffSplitSideSnapshot: Sendable, Equatable {
    /// Stable identity of the source unified row.
    let sourceID: String
    /// Semantic tint and marker classification.
    let kind: DiffRowKind
    /// Independent line number for this side.
    let lineNumber: Int?
    /// Source text.
    let text: String
    /// Character ranges that receive the stronger intraline tint.
    let intralineRanges: [DiffCharacterRange]
    /// Asynchronously produced syntax-highlighted source.
    let highlightedText: AttributedString?

    /// Creates a side snapshot from one unified code row.
    /// - Parameters:
    ///   - row: Unified source row.
    ///   - usesOldNumber: Whether to project the old or new line number.
    init(row: DiffRowSnapshot, usesOldNumber: Bool) {
        sourceID = row.id
        kind = row.kind
        lineNumber = usesOldNumber ? row.oldLineNumber : row.newLineNumber
        text = row.text
        intralineRanges = row.intralineRanges
        highlightedText = row.highlightedText
    }
}
