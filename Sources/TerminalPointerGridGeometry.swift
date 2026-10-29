import AppKit

/// Maps between a terminal view's AppKit points and its grid cells.
///
/// Every value is in the view's logical coordinate space. Ghostty's
/// `GHOSTTY_ACTION_CELL_SIZE` and `ghostty_surface_size` report backing
/// pixels, so dividing a mouse location by them halves the row and column on
/// a 2x display; build this from `ghostty_surface_grid_metrics` instead.
struct TerminalPointerGridGeometry: Equatable {
    let columns: Int
    let rows: Int
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let paddingLeft: CGFloat
    let paddingTop: CGFloat
    let viewHeight: CGFloat

    init?(
        columns: Int,
        rows: Int,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        paddingLeft: CGFloat,
        paddingTop: CGFloat,
        viewHeight: CGFloat
    ) {
        guard columns > 0, rows > 0,
              cellWidth.isFinite, cellWidth > 0,
              cellHeight.isFinite, cellHeight > 0,
              paddingLeft.isFinite, paddingTop.isFinite,
              viewHeight.isFinite else { return nil }
        self.columns = columns
        self.rows = rows
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paddingLeft = paddingLeft
        self.paddingTop = paddingTop
        self.viewHeight = viewHeight
    }

    /// The viewport cell under `point` (AppKit, bottom-left origin), clamped
    /// to the grid.
    func cell(at point: CGPoint) -> (row: Int, column: Int) {
        let yFromTop = viewHeight - point.y
        let row = Int(((yFromTop - paddingTop) / cellHeight).rounded(.down))
        let column = Int(((point.x - paddingLeft) / cellWidth).rounded(.down))
        return (
            row: max(0, min(rows - 1, row)),
            column: max(0, min(columns - 1, column))
        )
    }

    /// The center of a viewport cell, as x and distance from the view's top.
    func cellCenterFromTop(row: Int, column: Int) -> (x: CGFloat, yFromTop: CGFloat) {
        (
            x: paddingLeft + (CGFloat(column) + 0.5) * cellWidth,
            yFromTop: paddingTop + (CGFloat(row) + 0.5) * cellHeight
        )
    }
}
