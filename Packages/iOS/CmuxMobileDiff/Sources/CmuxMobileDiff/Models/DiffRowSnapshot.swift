internal import Foundation

/// An immutable, list-safe rendering snapshot for one diff row.
struct DiffRowSnapshot: Identifiable, Sendable, Equatable {
    /// Stable row identity.
    let id: String
    /// Semantic row presentation.
    let kind: DiffRowKind
    /// Old-side line number when present.
    let oldLineNumber: Int?
    /// New-side line number when present.
    let newLineNumber: Int?
    /// The unified marker shown between gutters and source.
    let marker: String
    /// Source or heading text.
    let text: String
    /// Character ranges that receive the stronger intraline tint.
    let intralineRanges: [DiffCharacterRange]
    /// Expansion metadata for gap rows.
    let expansionGap: DiffExpansionGap?
    /// Asynchronously produced syntax-highlighted source.
    var highlightedText: AttributedString?
    /// Old cell for a paired split row, or `nil` for right-only padding.
    let splitOldSide: DiffSplitSideSnapshot?
    /// New cell for a paired split row, or `nil` for left-only padding.
    let splitNewSide: DiffSplitSideSnapshot?
    /// Unified source identities represented by this projected row.
    let sourceRowIDs: [String]

    /// Creates an immutable row snapshot.
    init(
        id: String,
        kind: DiffRowKind,
        oldLineNumber: Int? = nil,
        newLineNumber: Int? = nil,
        marker: String = "",
        text: String,
        intralineRanges: [DiffCharacterRange] = [],
        expansionGap: DiffExpansionGap? = nil,
        highlightedText: AttributedString? = nil,
        splitOldSide: DiffSplitSideSnapshot? = nil,
        splitNewSide: DiffSplitSideSnapshot? = nil,
        sourceRowIDs: [String]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.marker = marker
        self.text = text
        self.intralineRanges = intralineRanges
        self.expansionGap = expansionGap
        self.highlightedText = highlightedText
        self.splitOldSide = splitOldSide
        self.splitNewSide = splitNewSide
        self.sourceRowIDs = sourceRowIDs ?? [id]
    }
}
