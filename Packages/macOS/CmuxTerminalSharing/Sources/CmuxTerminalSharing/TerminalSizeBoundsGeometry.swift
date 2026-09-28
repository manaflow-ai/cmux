import CmuxTerminalSizing
import CoreGraphics

/// Where a pane draws the shared grid's bounds.
///
/// Inputs are what the pane knows: its own size in points, the Ghostty
/// surface's applied pixel size (the grid plus padding), one cell in pixels,
/// the backing scale and the host's grid. The grid rect starts at the pane's
/// top-left; the pane draws a border and hatch when it is at least one cell
/// smaller than the pane, and a crop fade with a `+N` pill when the grid is
/// wider or taller than the pane.
public struct TerminalSizeBoundsGeometry: Hashable, Sendable {
    /// The visible part of the grid, in pane points with a top-left origin.
    public var gridRect: CGRect
    /// Columns cut off at the right edge.
    public var hiddenColumns: Int
    /// Rows cut off at the bottom edge.
    public var hiddenRows: Int
    /// Whether empty pane space surrounds the grid (draw border and hatch).
    public var showsBounds: Bool

    /// Computes the geometry.
    ///
    /// - Parameters:
    ///   - paneSize: the pane's content size in points.
    ///   - surfacePixelSize: the surface's applied size in pixels.
    ///   - cellPixelSize: one cell in pixels.
    ///   - scale: the backing scale factor.
    ///   - grid: the host's grid.
    public init(
        paneSize: CGSize,
        surfacePixelSize: CGSize,
        cellPixelSize: CGSize,
        scale: CGFloat,
        grid: TerminalGridSize
    ) {
        let scale = max(scale, 1)
        let gridWidth = surfacePixelSize.width / scale
        let gridHeight = surfacePixelSize.height / scale
        let cellWidth = max(cellPixelSize.width, 1) / scale
        let cellHeight = max(cellPixelSize.height, 1) / scale
        gridRect = CGRect(x: 0, y: 0, width: min(gridWidth, paneSize.width), height: min(gridHeight, paneSize.height))
        let overflowWidth = max(0, gridWidth - paneSize.width)
        let overflowHeight = max(0, gridHeight - paneSize.height)
        hiddenColumns = min(max(grid.cols - 1, 0), Int((overflowWidth / cellWidth).rounded(.up)))
        hiddenRows = min(max(grid.rows - 1, 0), Int((overflowHeight / cellHeight).rounded(.up)))
        showsBounds = paneSize.width - gridWidth >= cellWidth || paneSize.height - gridHeight >= cellHeight
    }

    /// Whether the pane needs any bounds decoration.
    public var needsDecoration: Bool { showsBounds || hiddenColumns > 0 || hiddenRows > 0 }
}
