import CoreGraphics

/// G-14 in a full-screen app (vim, htop): the cell grid of the surface on the
/// alternate screen, in the TUI host's coordinates. There is no scrollback, so
/// a cell's row is a viewport row (0 = the top row). The phone never forwards
/// touches as mouse events, so a long press always selects, like Shift-drag
/// in Ghostty when the app captures the mouse.
public struct TerminalTUISelectionGeometry: Equatable, Sendable {
    public var cellSize: CGSize
    /// The surface's grid padding (the surface sits at the host's origin).
    public var padding: CGPoint
    public var rows: Int
    public var columns: Int

    public init(cellSize: CGSize, padding: CGPoint, rows: Int, columns: Int) {
        self.cellSize = cellSize
        self.padding = padding
        self.rows = rows
        self.columns = columns
    }

    /// The cell under `point`, clamped to the grid (nil when there is no grid).
    public func cell(at point: CGPoint) -> TerminalCellPoint? {
        guard rows > 0, columns > 0, cellSize.width > 0, cellSize.height > 0 else { return nil }
        let row = Int(floor((point.y - padding.y) / cellSize.height))
        let column = Int(floor((point.x - padding.x) / cellSize.width))
        return TerminalCellPoint(row: min(max(0, row), rows - 1), column: min(max(0, column), columns - 1))
    }

    public func rect(for cell: TerminalCellPoint) -> CGRect {
        CGRect(x: padding.x + CGFloat(cell.column) * cellSize.width, y: padding.y + CGFloat(cell.row) * cellSize.height,
               width: cellSize.width, height: cellSize.height)
    }

    /// Select All: the whole screen.
    public var all: TerminalTextSelection {
        TerminalTextSelection.all(originRow: 0, endRow: max(1, rows), columns: max(1, columns))
    }
}
