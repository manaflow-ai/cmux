/// Maps view points to terminal cells and back, from Ghostty's grid metrics
/// (points, after padding). A host-locked grid larger than the view is
/// cropped at the right and bottom; one smaller is padded.
public struct TerminalCellGeometry: Hashable, Sendable {
    public var cols: Int
    public var rows: Int
    public var cellWidth: Double
    public var cellHeight: Double
    public var paddingLeft: Double
    public var paddingTop: Double

    public init(cols: Int, rows: Int, cellWidth: Double, cellHeight: Double,
                paddingLeft: Double = 0, paddingTop: Double = 0) {
        self.cols = max(cols, 0)
        self.rows = max(rows, 0)
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paddingLeft = paddingLeft
        self.paddingTop = paddingTop
    }

    public struct Cell: Hashable, Sendable {
        public var column: Int
        public var row: Int
        public init(column: Int, row: Int) {
            self.column = column
            self.row = row
        }
    }

    public var isValid: Bool { cols > 0 && rows > 0 && cellWidth > 0 && cellHeight > 0 }

    /// The cell under a point, or nil outside the grid (in the padding).
    public func cell(atX x: Double, y: Double) -> Cell? {
        guard isValid else { return nil }
        let column = Int(((x - paddingLeft) / cellWidth).rounded(.down))
        let row = Int(((y - paddingTop) / cellHeight).rounded(.down))
        guard (0..<cols).contains(column), (0..<rows).contains(row) else { return nil }
        return Cell(column: column, row: row)
    }

    /// The nearest cell, clamped into the grid (for drag handles past an edge).
    public func clampedCell(atX x: Double, y: Double) -> Cell? {
        guard isValid else { return nil }
        let column = Int(((x - paddingLeft) / cellWidth).rounded(.down))
        let row = Int(((y - paddingTop) / cellHeight).rounded(.down))
        return Cell(column: min(max(column, 0), cols - 1), row: min(max(row, 0), rows - 1))
    }

    /// A cell's frame in points: (x, y, width, height).
    public func frame(of cell: Cell, widthCells: Int = 1) -> (x: Double, y: Double, width: Double, height: Double) {
        (paddingLeft + Double(cell.column) * cellWidth, paddingTop + Double(cell.row) * cellHeight,
         cellWidth * Double(max(widthCells, 1)), cellHeight)
    }

    /// The center of a cell, where a synthesized mouse event lands.
    public func center(of cell: Cell) -> (x: Double, y: Double) {
        let frame = frame(of: cell)
        return (frame.x + frame.width / 2, frame.y + frame.height / 2)
    }
}
