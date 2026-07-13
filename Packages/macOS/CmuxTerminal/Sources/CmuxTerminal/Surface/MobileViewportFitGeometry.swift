import Foundation

/// Pure pixel and font-fit math for Mac panes mirroring a mobile terminal viewport.
///
/// The mobile viewport grant is expressed in terminal cells. This helper keeps
/// the grant as the preferred grid, then computes the runtime font size and
/// fallback grid needed for that grid to fit inside the Mac pane without
/// clipping.
public struct MobileViewportFitGeometry {
    /// The Mac pane width in backing pixels.
    public let paneWidthPx: Int
    /// The Mac pane height in backing pixels.
    public let paneHeightPx: Int
    /// The measured terminal cell width in backing pixels.
    public let cellWidthPx: Double
    /// The measured terminal cell height in backing pixels.
    public let cellHeightPx: Double
    /// Pixels reserved outside the cell grid on the horizontal axis.
    public let horizontalNonGridPixels: Int
    /// Pixels reserved outside the cell grid on the vertical axis.
    public let verticalNonGridPixels: Int

    /// The minimum runtime font size used by mobile viewport fitting.
    public static let defaultFontFloorPointSize: Float = 6

    /// Creates geometry for one measured pane/cell state.
    ///
    /// - Parameters:
    ///   - paneWidthPx: The Mac pane width in backing pixels.
    ///   - paneHeightPx: The Mac pane height in backing pixels.
    ///   - cellWidthPx: The measured terminal cell width in backing pixels.
    ///   - cellHeightPx: The measured terminal cell height in backing pixels.
    ///   - horizontalNonGridPixels: Pixels reserved outside the cell grid on the horizontal axis.
    ///   - verticalNonGridPixels: Pixels reserved outside the cell grid on the vertical axis.
    public init(
        paneWidthPx: Int,
        paneHeightPx: Int,
        cellWidthPx: Double,
        cellHeightPx: Double,
        horizontalNonGridPixels: Int,
        verticalNonGridPixels: Int
    ) {
        self.paneWidthPx = paneWidthPx
        self.paneHeightPx = paneHeightPx
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.horizontalNonGridPixels = horizontalNonGridPixels
        self.verticalNonGridPixels = verticalNonGridPixels
    }

    /// The pixel box required to render a grid at the measured cell size.
    ///
    /// - Parameters:
    ///   - columns: The grid column count.
    ///   - rows: The grid row count.
    /// - Returns: The pixel box for the grid plus non-grid padding.
    public func grantPixelBox(columns: Int, rows: Int) -> (width: UInt32, height: UInt32) {
        (
            width: Self.safePixelDimension(
                cellCount: columns,
                cellSizePx: cellWidthPx,
                nonGridPixels: horizontalNonGridPixels
            ),
            height: Self.safePixelDimension(
                cellCount: rows,
                cellSizePx: cellHeightPx,
                nonGridPixels: verticalNonGridPixels
            )
        )
    }

    /// The runtime font point size that should make the requested grid fit.
    ///
    /// Cell pixels are normalized to the base font size with a linear estimate.
    /// The returned value is clamped to the font floor and never grows above
    /// the base font.
    ///
    /// - Parameters:
    ///   - baseFontPointSize: The runtime point size to restore when fitting clears.
    ///   - currentFontPointSize: The runtime point size for the measured cells.
    ///   - columns: The granted mobile viewport columns.
    ///   - rows: The granted mobile viewport rows.
    ///   - fontFloorPointSize: The lowest runtime point size fitting may request.
    /// - Returns: The target runtime font size in points.
    public func targetFontPointSize(
        baseFontPointSize: Float,
        currentFontPointSize: Float,
        columns: Int,
        rows: Int,
        fontFloorPointSize: Float = Self.defaultFontFloorPointSize
    ) -> Float {
        let baseFont = Self.safeFont(baseFontPointSize)
        let currentFont = Self.safeFont(currentFontPointSize)
        let floorFont = min(baseFont, Self.safeFont(fontFloorPointSize))
        let baseCellWidth = Self.normalizedBaseCellSize(
            measuredCellPx: cellWidthPx,
            baseFontPointSize: baseFont,
            currentFontPointSize: currentFont
        )
        let baseCellHeight = Self.normalizedBaseCellSize(
            measuredCellPx: cellHeightPx,
            baseFontPointSize: baseFont,
            currentFontPointSize: currentFont
        )
        let usableWidth = max(1, paneWidthPx - max(0, horizontalNonGridPixels))
        let usableHeight = max(1, paneHeightPx - max(0, verticalNonGridPixels))
        let fitW = Double(usableWidth) / (Double(max(1, columns)) * baseCellWidth)
        let fitH = Double(usableHeight) / (Double(max(1, rows)) * baseCellHeight)
        let scale = min(1, fitW, fitH)
        let target = baseFont * Float(scale.isFinite ? scale : 1)
        return min(baseFont, max(floorFont, target))
    }

    /// The largest grid that fits at the measured cell size, capped by the mobile grant.
    ///
    /// This is the floor-font fallback: each axis is capped independently, and
    /// the returned pixel box is additionally clamped to the pane so callers
    /// never request a clipped render size for degenerate panes.
    ///
    /// - Parameters:
    ///   - grantedColumns: The columns requested by the mobile viewport.
    ///   - grantedRows: The rows requested by the mobile viewport.
    /// - Returns: The capped grid and its safe pixel box.
    public func cappedFallbackGrant(
        grantedColumns: Int,
        grantedRows: Int
    ) -> (columns: Int, rows: Int, width: UInt32, height: UInt32) {
        let columns = min(
            max(1, grantedColumns),
            Self.maxCellsThatFit(
                panePixels: paneWidthPx,
                cellSizePx: cellWidthPx,
                nonGridPixels: horizontalNonGridPixels
            )
        )
        let rows = min(
            max(1, grantedRows),
            Self.maxCellsThatFit(
                panePixels: paneHeightPx,
                cellSizePx: cellHeightPx,
                nonGridPixels: verticalNonGridPixels
            )
        )
        let box = grantPixelBox(columns: columns, rows: rows)
        return (
            columns: columns,
            rows: rows,
            width: min(box.width, UInt32(max(1, paneWidthPx))),
            height: min(box.height, UInt32(max(1, paneHeightPx)))
        )
    }

    /// Whether a re-measured grant box still overflows the pane.
    ///
    /// Callers use this as a convergence guard after changing the font. A true
    /// result means one more font-size step may be needed, bounded by the caller.
    ///
    /// - Parameters:
    ///   - grantWidthPx: The measured grant width in backing pixels.
    ///   - grantHeightPx: The measured grant height in backing pixels.
    /// - Returns: True when the grant still exceeds the pane on either axis.
    public func needsRefinement(grantWidthPx: UInt32, grantHeightPx: UInt32) -> Bool {
        Int(grantWidthPx) > max(1, paneWidthPx) || Int(grantHeightPx) > max(1, paneHeightPx)
    }

    /// The target font size for a measured grid using whole-cell targets.
    ///
    /// This is the steady-state fit equation. It uses integer target cell
    /// pixels instead of continuous grant-box scale so a converged quantized
    /// cell size is a fixed point, while pane growth can still raise the font
    /// back toward the base size.
    ///
    /// - Parameters:
    ///   - baseFontPointSize: The runtime point size to restore when fitting clears.
    ///   - currentFontPointSize: The runtime point size for the measured cells.
    ///   - columns: The granted mobile viewport columns.
    ///   - rows: The granted mobile viewport rows.
    ///   - fontFloorPointSize: The lowest runtime point size fitting may request.
    /// - Returns: The next runtime font size in points, clamped to the floor and base size.
    public func integerCellTargetFontPointSize(
        baseFontPointSize: Float,
        currentFontPointSize: Float,
        columns: Int,
        rows: Int,
        fontFloorPointSize: Float = Self.defaultFontFloorPointSize
    ) -> Float {
        let baseFont = Self.safeFont(baseFontPointSize)
        let currentFont = Self.safeFont(currentFontPointSize)
        let floorFont = min(baseFont, Self.safeFont(fontFloorPointSize))
        let usableWidth = max(0, paneWidthPx - max(0, horizontalNonGridPixels))
        let usableHeight = max(0, paneHeightPx - max(0, verticalNonGridPixels))
        let targetCellWidth = floor(Double(usableWidth) / Double(max(1, columns)))
        let targetCellHeight = floor(Double(usableHeight) / Double(max(1, rows)))
        let fitW = targetCellWidth / Self.safeCellSize(cellWidthPx)
        let fitH = targetCellHeight / Self.safeCellSize(cellHeightPx)
        let scale = min(fitW, fitH)
        let target = currentFont * Float(scale.isFinite ? scale : 1)
        return min(baseFont, max(floorFont, target))
    }

    /// The next font size for an overflowing measured grid using whole-cell targets.
    ///
    /// This is the corrective refinement step after a real measurement still
    /// overflows. It intentionally uses integer target cell pixels so a small
    /// overflow cannot be hidden by font-size hysteresis while the rendered
    /// cell size is quantized to whole pixels.
    ///
    /// - Parameters:
    ///   - currentFontPointSize: The runtime point size for the measured cells.
    ///   - columns: The granted mobile viewport columns.
    ///   - rows: The granted mobile viewport rows.
    ///   - fontFloorPointSize: The lowest runtime point size fitting may request.
    /// - Returns: The next runtime font size in points, clamped to the floor.
    public func correctiveFontPointSizeForOverflow(
        currentFontPointSize: Float,
        columns: Int,
        rows: Int,
        fontFloorPointSize: Float = Self.defaultFontFloorPointSize
    ) -> Float {
        let currentFont = Self.safeFont(currentFontPointSize)
        return integerCellTargetFontPointSize(
            baseFontPointSize: currentFont,
            currentFontPointSize: currentFont,
            columns: columns,
            rows: rows,
            fontFloorPointSize: fontFloorPointSize
        )
    }

    /// The cell count represented by a pixel dimension and measured cell size.
    ///
    /// - Parameters:
    ///   - pixelDimension: The surface pixel dimension.
    ///   - cellSizePx: The measured cell size in backing pixels.
    ///   - nonGridPixels: Pixels reserved outside the cell grid on the same axis.
    /// - Returns: The largest whole-cell count represented by the dimension.
    public static func cellCount(pixelDimension: UInt32, cellSizePx: Double, nonGridPixels: Int) -> Int {
        let gridPixels = max(0, Int(pixelDimension) - max(0, nonGridPixels))
        return max(1, Int(Double(gridPixels) / safeCellSize(cellSizePx)))
    }

    /// The base-font cell size estimated from a current measured cell.
    ///
    /// - Parameters:
    ///   - measuredCellPx: The currently measured cell size in backing pixels.
    ///   - baseFontPointSize: The runtime point size to restore when fitting clears.
    ///   - currentFontPointSize: The runtime point size for the measured cell.
    /// - Returns: The estimated cell size at the base font.
    public static func normalizedBaseCellSize(
        measuredCellPx: Double,
        baseFontPointSize: Float,
        currentFontPointSize: Float
    ) -> Double {
        let currentFont = safeFont(currentFontPointSize)
        let baseFont = safeFont(baseFontPointSize)
        return safeCellSize(measuredCellPx) * Double(baseFont / currentFont)
    }

    private static func safePixelDimension(cellCount: Int, cellSizePx: Double, nonGridPixels: Int) -> UInt32 {
        let cellSize = safeCellSize(cellSizePx)
        let cells = Double(max(1, cellCount))
        let padding = Double(max(0, nonGridPixels))
        let value = (cells * cellSize + padding).rounded(.down)
        guard value.isFinite, value > 0 else { return 1 }
        return UInt32(min(value, Double(UInt32.max)))
    }

    private static func maxCellsThatFit(panePixels: Int, cellSizePx: Double, nonGridPixels: Int) -> Int {
        let usablePixels = max(0, panePixels - max(0, nonGridPixels))
        guard usablePixels > 0 else { return 1 }
        return max(1, Int(Double(usablePixels) / safeCellSize(cellSizePx)))
    }

    private static func safeCellSize(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return value
    }

    private static func safeFont(_ value: Float) -> Float {
        guard value.isFinite, value > 0 else { return 1 }
        return value
    }
}
