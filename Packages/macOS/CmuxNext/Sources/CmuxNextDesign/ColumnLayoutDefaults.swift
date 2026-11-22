/// cmux.json `layout.splitSizing`: what a split does to its column
/// (plans/cmux-next/column-sizing.md).
public nonisolated enum SplitSizing: String, Hashable, Sendable, CaseIterable {
    /// Every pane along the split axis in that column gets an equal share.
    case even
    /// Only the split pane halves; the others keep their size.
    case halve
}

/// cmux.json `layout.newColumnWidth`: the width of a new column.
public nonisolated enum NewColumnWidthMode: String, Hashable, Sendable, CaseIterable {
    /// The width of the column it opens next to; no column resizes.
    case matchCurrent
    /// The visible scrolling columns and the new one share the strip.
    case fitScreen
    /// `layout.defaultColumnWidth` (a share of the viewport).
    case fixed
}
