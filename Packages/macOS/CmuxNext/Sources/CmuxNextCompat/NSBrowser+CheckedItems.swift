public import AppKit

/// Checked item lookups for an item-based `NSBrowser`.
///
/// `item(atRow:inColumn:)` raises `NSRangeException` for a column the browser has not loaded, and
/// `clickedColumn` / `selectedColumn` are -1 when a click lands below the last row or nothing is
/// selected: the Files pane's column view ended the app that way (#24776). Read rows and columns
/// through these accessors, never through the raw indices.
public extension NSBrowser {
    /// The item at `row` in `column`, or nil when either index is outside what the browser has loaded.
    ///
    /// Item-based browsers only: the row count comes from the delegate's
    /// `browser(_:numberOfChildrenOfItem:)`, so a matrix-based browser always gets nil.
    /// - Parameters:
    ///   - row: A row index, possibly -1 (no row).
    ///   - column: A column index, possibly -1 (no column).
    /// - Returns: The delegate's item, or nil for an index the browser would raise on.
    func item(ifValidRow row: Int, inColumn column: Int) -> Any? {
        guard row >= 0, column >= 0, column <= lastColumn else { return nil }
        let parent = parentForItems(inColumn: column) // index-allow: column checked against lastColumn above
        guard let count = delegate?.browser?(self, numberOfChildrenOfItem: parent), row < count else { return nil }
        return item(atRow: row, inColumn: column) // index-allow: row and column checked above
    }

    /// The item the last click or double-click landed on, or nil when it landed on no row.
    var clickedItemIfValid: Any? {
        item(ifValidRow: clickedRow, inColumn: clickedColumn) // index-allow: the checked accessor
    }

    /// The selected item of the last column that has a selection, or nil when nothing is selected.
    var selectedItemIfValid: Any? {
        let column = selectedColumn // index-allow: checked before use
        guard column >= 0, column <= lastColumn else { return nil }
        return item(ifValidRow: selectedRow(inColumn: column), inColumn: column) // index-allow: column checked above
    }
}
