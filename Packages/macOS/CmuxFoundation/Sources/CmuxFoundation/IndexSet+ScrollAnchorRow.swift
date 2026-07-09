public import Foundation

extension IndexSet {
    /// Picks the row to scroll into view after restoring a multi-row selection.
    /// Prefers `anchorRow` when it is still part of `self` (the restored exact
    /// rows); otherwise falls back to the first element, or `nil` when empty.
    public func scrollAnchorRow(preferring anchorRow: Int?) -> Int? {
        if let anchorRow, contains(anchorRow) {
            return anchorRow
        }
        return first
    }
}
