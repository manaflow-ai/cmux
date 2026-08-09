import Foundation

/// Swift mirror of Ghostty's `ghostty_external_hover_cell_range_s`. `row`
/// is an ABSOLUTE VIEWPORT row (the same coordinate space as
/// `ghostty_surface_grid_metrics`'s rows / `GHOSTTY_POINT_VIEWPORT`) — NOT
/// relative to the setter call's `top_row`. `startColumn`/`endColumn` are
/// half-open.
///
/// A caller materializes this from a resolved
/// `TerminalWrappedPathCellSpan` (row-relative-to-clicked) by adding the
/// clicked row's own absolute viewport row to `rowOffsetFromClicked` —
/// this type deliberately carries no reference to how it was derived, only
/// the final absolute coordinates the setter needs.
public struct ExternalHoverCellRangeValue: Sendable, Equatable {
    public let row: UInt16
    public let startColumn: UInt16
    public let endColumn: UInt16

    public init(row: UInt16, startColumn: UInt16, endColumn: UInt16) {
        self.row = row
        self.startColumn = startColumn
        self.endColumn = endColumn
    }
}
