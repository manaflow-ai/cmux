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
}
