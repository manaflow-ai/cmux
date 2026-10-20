/// Immutable presentation data for one still-hidden run inside a diff gap.
struct DiffExpanderSnapshot: Sendable, Equatable {
    let gap: DiffGap
    /// One-based new-file range, or `nil` for unresolved trailing context.
    let hiddenNewLineRange: Range<Int>?

    var expansionLineCount: Int? {
        hiddenNewLineRange.map { range in
            range.count <= DiffExpansionState.shortRunThreshold
                ? range.count
                : min(DiffExpansionState.stepLineCount, range.count)
        }
    }

    /// Whether one tap reveals the whole run, making direction irrelevant.
    /// The row then renders a single unified button instead of a split pair,
    /// since two buttons with identical outcomes read as a confusing duplicate.
    var revealsCompletely: Bool {
        hiddenNewLineRange.map { $0.count <= DiffExpansionState.shortRunThreshold } ?? false
    }
}
