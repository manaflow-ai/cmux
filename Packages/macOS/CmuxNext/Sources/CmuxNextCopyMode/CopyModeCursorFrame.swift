public import CoreGraphics

/// Where the copy-mode cursor box goes over a terminal view.
///
/// Ghostty reports the grid in the view's points with a top-left origin
/// (`ghostty_surface_grid_metrics`); AppKit views are bottom-left. The box
/// covers `widthCells` cells (2 for a wide glyph) and stays inside the view.
public struct CopyModeCursorFrame: Equatable, Sendable {
    public var cellWidth: Double
    public var cellHeight: Double
    public var paddingLeft: Double
    public var paddingTop: Double
    public var viewHeight: Double

    /// `nil` unless both cell sizes are positive and every value is finite.
    public init?(cellWidth: Double, cellHeight: Double, paddingLeft: Double, paddingTop: Double, viewHeight: Double) {
        guard [cellWidth, cellHeight, paddingLeft, paddingTop, viewHeight].allSatisfy(\.isFinite),
              cellWidth > 0, cellHeight > 0 else { return nil }
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paddingLeft = paddingLeft
        self.paddingTop = paddingTop
        self.viewHeight = viewHeight
    }

    /// The cell's rectangle in AppKit coordinates.
    public func rect(column: Int, row: Int, widthCells: Int) -> CGRect {
        let x = paddingLeft + Double(column) * cellWidth
        let topY = paddingTop + Double(row) * cellHeight
        let y = min(max(viewHeight - (topY + cellHeight), 0), max(viewHeight - cellHeight, 0))
        return CGRect(x: x, y: y, width: cellWidth * Double(max(widthCells, 1)), height: cellHeight)
    }
}
