public import AppKit

/// Checked row lookups for `NSTableView` and `NSOutlineView`.
///
/// `clickedRow` and `selectedRow` are -1 when a click lands off the rows or nothing is selected,
/// and a row index read before a reload can be past the end after it. Passing such an index to
/// AppKit (`view(atColumn:row:)`, `item(atRow:)`, `rowView(atRow:)`) or to a model array raises or
/// traps (#24776's class). Read rows through these accessors; still check the index against the
/// model array you index with it.
public extension NSTableView {
    /// The row the last click or double-click landed on, or nil when it landed on no row.
    var clickedRowIfValid: Int? {
        let row = clickedRow // index-allow: the checked accessor
        return row >= 0 && row < numberOfRows ? row : nil
    }

    /// The last selected row, or nil when nothing is selected.
    var selectedRowIfValid: Int? {
        let row = selectedRow
        return row >= 0 && row < numberOfRows ? row : nil
    }
}
