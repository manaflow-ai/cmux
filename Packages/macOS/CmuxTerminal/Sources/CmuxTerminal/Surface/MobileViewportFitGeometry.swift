import Foundation

/// Pure pixel and font-fit math for Mac panes mirroring a mobile terminal viewport.
///
/// The mobile viewport grant is expressed in terminal cells. This helper keeps
/// the grant as the preferred grid, then computes the runtime font size and
/// fallback grid needed for that grid to fit inside the Mac pane without
/// clipping.
public struct MobileViewportFitGeometry {
    private init() {}

    /// The minimum runtime font size used by mobile viewport fitting.
    public static let defaultFontFloorPointSize: Float = 6

    /// The pixel box required to render a grid at a measured cell size.
    ///
    /// - Parameters:
    ///   - columns: The grid column count.
    ///   - rows: The grid row count.
    ///   - cellWidthPx: The measured cell width in backing pixels.
    ///   - cellHeightPx: The measured cell height in backing pixels.
    ///   - horizontalNonGridPixels: Pixels reserved outside the cell grid on the horizontal axis.
    ///   - verticalNonGridPixels: Pixels reserved outside the cell grid on the vertical axis.
    /// - Returns: The pixel box for the grid plus non-grid padding.
    public static func grantPixelBox(
        columns: Int,
        rows: Int,
        cellWidthPx: Double,
        cellHeightPx: Double,
        horizontalNonGridPixels: Int,
        verticalNonGridPixels: Int
    ) -> (width: UInt32, height: UInt32) {
        (
            width: safePixelDimension(
                cellCount: columns,
                cellSizePx: cellWidthPx,
                nonGridPixels: horizontalNonGridPixels
            ),
            height: safePixelDimension(
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
    ///   - paneWidthPx: The Mac pane width in backing pixels.
    ///   - paneHeightPx: The Mac pane height in backing pixels.
    ///   - measuredCellWidthPx: The currently measured cell width in backing pixels.
    ///   - measuredCellHeightPx: The currently measured cell height in backing pixels.
    ///   - baseFontPointSize: The runtime point size to restore when fitting clears.
    ///   - currentFontPointSize: The runtime point size for the measured cells.
    ///   - columns: The granted mobile viewport columns.
    ///   - rows: The granted mobile viewport rows.
    ///   - horizontalNonGridPixels: Pixels reserved outside the cell grid on the horizontal axis.
    ///   - verticalNonGridPixels: Pixels reserved outside the cell grid on the vertical axis.
    ///   - fontFloorPointSize: The lowest runtime point size fitting may request.
    /// - Returns: The target runtime font size in points.
    public static func targetFontPointSize(
        paneWidthPx: Int,
        paneHeightPx: Int,
        measuredCellWidthPx: Double,
        measuredCellHeightPx: Double,
        baseFontPointSize: Float,
        currentFontPointSize: Float,
        columns: Int,
        rows: Int,
        horizontalNonGridPixels: Int,
        verticalNonGridPixels: Int,
        fontFloorPointSize: Float = Self.defaultFontFloorPointSize
    ) -> Float {
        let baseFont = safeFont(baseFontPointSize)
        let currentFont = safeFont(currentFontPointSize)
        let floorFont = min(baseFont, safeFont(fontFloorPointSize))
        let baseCellWidth = normalizedBaseCellSize(
            measuredCellPx: measuredCellWidthPx,
            baseFontPointSize: baseFont,
            currentFontPointSize: currentFont
        )
        let baseCellHeight = normalizedBaseCellSize(
            measuredCellPx: measuredCellHeightPx,
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

    /// The largest grid that fits at a measured cell size, capped by the mobile grant.
    ///
    /// This is the floor-font fallback: each axis is capped independently, and
    /// the returned pixel box is additionally clamped to the pane so callers
    /// never request a clipped render size for degenerate panes.
    ///
    /// - Parameters:
    ///   - grantedColumns: The columns requested by the mobile viewport.
    ///   - grantedRows: The rows requested by the mobile viewport.
    ///   - paneWidthPx: The Mac pane width in backing pixels.
    ///   - paneHeightPx: The Mac pane height in backing pixels.
    ///   - cellWidthPxAtFloor: The measured cell width at the floor font.
    ///   - cellHeightPxAtFloor: The measured cell height at the floor font.
    ///   - horizontalNonGridPixels: Pixels reserved outside the cell grid on the horizontal axis.
    ///   - verticalNonGridPixels: Pixels reserved outside the cell grid on the vertical axis.
    /// - Returns: The capped grid and its safe pixel box.
    public static func cappedFallbackGrant(
        grantedColumns: Int,
        grantedRows: Int,
        paneWidthPx: Int,
        paneHeightPx: Int,
        cellWidthPxAtFloor: Double,
        cellHeightPxAtFloor: Double,
        horizontalNonGridPixels: Int,
        verticalNonGridPixels: Int
    ) -> (columns: Int, rows: Int, width: UInt32, height: UInt32) {
        let columns = min(
            max(1, grantedColumns),
            maxCellsThatFit(
                panePixels: paneWidthPx,
                cellSizePx: cellWidthPxAtFloor,
                nonGridPixels: horizontalNonGridPixels
            )
        )
        let rows = min(
            max(1, grantedRows),
            maxCellsThatFit(
                panePixels: paneHeightPx,
                cellSizePx: cellHeightPxAtFloor,
                nonGridPixels: verticalNonGridPixels
            )
        )
        let box = grantPixelBox(
            columns: columns,
            rows: rows,
            cellWidthPx: cellWidthPxAtFloor,
            cellHeightPx: cellHeightPxAtFloor,
            horizontalNonGridPixels: horizontalNonGridPixels,
            verticalNonGridPixels: verticalNonGridPixels
        )
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
    ///   - paneWidthPx: The Mac pane width in backing pixels.
    ///   - paneHeightPx: The Mac pane height in backing pixels.
    /// - Returns: True when the grant still exceeds the pane on either axis.
    public static func needsRefinement(
        grantWidthPx: UInt32,
        grantHeightPx: UInt32,
        paneWidthPx: Int,
        paneHeightPx: Int
    ) -> Bool {
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
    ///   - paneWidthPx: The Mac pane width in backing pixels.
    ///   - paneHeightPx: The Mac pane height in backing pixels.
    ///   - measuredCellWidthPx: The currently measured cell width in backing pixels.
    ///   - measuredCellHeightPx: The currently measured cell height in backing pixels.
    ///   - baseFontPointSize: The runtime point size to restore when fitting clears.
    ///   - currentFontPointSize: The runtime point size for the measured cells.
    ///   - columns: The granted mobile viewport columns.
    ///   - rows: The granted mobile viewport rows.
    ///   - horizontalNonGridPixels: Pixels reserved outside the cell grid on the horizontal axis.
    ///   - verticalNonGridPixels: Pixels reserved outside the cell grid on the vertical axis.
    ///   - fontFloorPointSize: The lowest runtime point size fitting may request.
    /// - Returns: The next runtime font size in points, clamped to the floor and base size.
    public static func integerCellTargetFontPointSize(
        paneWidthPx: Int,
        paneHeightPx: Int,
        measuredCellWidthPx: Double,
        measuredCellHeightPx: Double,
        baseFontPointSize: Float,
        currentFontPointSize: Float,
        columns: Int,
        rows: Int,
        horizontalNonGridPixels: Int,
        verticalNonGridPixels: Int,
        fontFloorPointSize: Float = Self.defaultFontFloorPointSize
    ) -> Float {
        let baseFont = safeFont(baseFontPointSize)
        let currentFont = safeFont(currentFontPointSize)
        let floorFont = min(baseFont, safeFont(fontFloorPointSize))
        let usableWidth = max(0, paneWidthPx - max(0, horizontalNonGridPixels))
        let usableHeight = max(0, paneHeightPx - max(0, verticalNonGridPixels))
        let targetCellWidth = floor(Double(usableWidth) / Double(max(1, columns)))
        let targetCellHeight = floor(Double(usableHeight) / Double(max(1, rows)))
        let fitW = targetCellWidth / safeCellSize(measuredCellWidthPx)
        let fitH = targetCellHeight / safeCellSize(measuredCellHeightPx)
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
    ///   - paneWidthPx: The Mac pane width in backing pixels.
    ///   - paneHeightPx: The Mac pane height in backing pixels.
    ///   - measuredCellWidthPx: The currently measured cell width in backing pixels.
    ///   - measuredCellHeightPx: The currently measured cell height in backing pixels.
    ///   - currentFontPointSize: The runtime point size for the measured cells.
    ///   - columns: The granted mobile viewport columns.
    ///   - rows: The granted mobile viewport rows.
    ///   - horizontalNonGridPixels: Pixels reserved outside the cell grid on the horizontal axis.
    ///   - verticalNonGridPixels: Pixels reserved outside the cell grid on the vertical axis.
    ///   - fontFloorPointSize: The lowest runtime point size fitting may request.
    /// - Returns: The next runtime font size in points, clamped to the floor.
    public static func correctiveFontPointSizeForOverflow(
        paneWidthPx: Int,
        paneHeightPx: Int,
        measuredCellWidthPx: Double,
        measuredCellHeightPx: Double,
        currentFontPointSize: Float,
        columns: Int,
        rows: Int,
        horizontalNonGridPixels: Int,
        verticalNonGridPixels: Int,
        fontFloorPointSize: Float = Self.defaultFontFloorPointSize
    ) -> Float {
        let currentFont = safeFont(currentFontPointSize)
        return integerCellTargetFontPointSize(
            paneWidthPx: paneWidthPx,
            paneHeightPx: paneHeightPx,
            measuredCellWidthPx: measuredCellWidthPx,
            measuredCellHeightPx: measuredCellHeightPx,
            baseFontPointSize: currentFont,
            currentFontPointSize: currentFont,
            columns: columns,
            rows: rows,
            horizontalNonGridPixels: horizontalNonGridPixels,
            verticalNonGridPixels: verticalNonGridPixels,
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
    public static func cellCount(
        pixelDimension: UInt32,
        cellSizePx: Double,
        nonGridPixels: Int
    ) -> Int {
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
