import Testing
@testable import CmuxNextTerminalGeometry

/// The fit must agree with Ghostty's own sizing, or the surface would report
/// one grid and Ghostty would lay out another (a rounding mismatch).
struct TerminalGridMetricsTests {
    /// 14 x 30 px cells, 2 pt (4 px) padding on every side.
    static let metrics = TerminalGridMetrics(cellWidth: 14, cellHeight: 30, paddingWidth: 8, paddingHeight: 8)

    @Test func paddingIsTheResolvedSizeMinusTheCells() {
        let grid = TerminalGridSize(columns: 84, rows: 25)
        let resolved = TerminalGridMetrics(resolving: grid, widthPixels: 84 * 14 + 8, heightPixels: 25 * 30 + 8,
                                           cellWidth: 14, cellHeight: 30)
        #expect(resolved == Self.metrics)
        #expect(TerminalGridMetrics(resolving: grid, widthPixels: 10, heightPixels: 10, cellWidth: 14, cellHeight: 30) == nil)
        #expect(TerminalGridMetrics(resolving: grid, widthPixels: 2000, heightPixels: 2000, cellWidth: 0, cellHeight: 30) == nil)
    }

    @Test func fitMatchesGhosttyGridSizeUpdate() {
        // A view exactly as wide as 84 cells plus padding fits 84; one pixel
        // less fits 83; up to one cell more still fits 84.
        #expect(Self.metrics.grid(fittingWidth: 84 * 14 + 8, height: 25 * 30 + 8) == TerminalGridSize(columns: 84, rows: 25))
        #expect(Self.metrics.grid(fittingWidth: 84 * 14 + 7, height: 25 * 30 + 7) == TerminalGridSize(columns: 83, rows: 24))
        #expect(Self.metrics.grid(fittingWidth: 85 * 14 + 7, height: 26 * 30 + 7) == TerminalGridSize(columns: 84, rows: 25))
        // A 595 x 355 pt pane at 2x.
        #expect(Self.metrics.grid(fittingWidth: 1190, height: 710) == TerminalGridSize(columns: 84, rows: 23))
    }

    @Test func fitNeverReturnsAnEmptyGrid() {
        #expect(Self.metrics.grid(fittingWidth: 0, height: 0) == TerminalGridSize(columns: 1, rows: 1))
        #expect(Self.metrics.grid(fittingWidth: 5, height: 5) == TerminalGridSize(columns: 1, rows: 1))
    }

    @Test func resolvedGridRoundTrips() {
        for columns in 1...300 {
            let grid = TerminalGridSize(columns: columns, rows: columns % 97 + 1)
            let (width, height) = Self.metrics.cellPixels(of: grid)
            let fit = Self.metrics.grid(fittingWidth: width + Self.metrics.paddingWidth,
                                        height: height + Self.metrics.paddingHeight)
            #expect(fit == grid)
        }
    }
}
