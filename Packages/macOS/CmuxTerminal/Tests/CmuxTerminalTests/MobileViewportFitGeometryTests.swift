import Testing

@testable import CmuxTerminal

@Suite("Mobile viewport fit geometry")
struct MobileViewportFitGeometryTests {
    @Test func fitNotNeededKeepsBaseFontAndGrantBox() {
        let geometry = geometry(paneWidthPx: 1000, paneHeightPx: 600, cellWidthPx: 10, cellHeightPx: 20)
        let font = geometry.targetFontPointSize(
            baseFontPointSize: 12,
            currentFontPointSize: 12,
            columns: 80,
            rows: 24
        )
        let box = geometry.grantPixelBox(columns: 80, rows: 24)
        #expect(font == 12)
        #expect(box.width == 800)
        #expect(box.height == 480)
    }

    @Test func widthConstrainedGrantShrinksFont() {
        let font = geometry(paneWidthPx: 600, paneHeightPx: 600, cellWidthPx: 10, cellHeightPx: 20)
            .targetFontPointSize(baseFontPointSize: 12, currentFontPointSize: 12, columns: 80, rows: 24)
        #expect(font == 9)
    }

    @Test func heightConstrainedGrantShrinksFont() {
        let font = geometry(paneWidthPx: 1000, paneHeightPx: 360, cellWidthPx: 10, cellHeightPx: 20)
            .targetFontPointSize(baseFontPointSize: 12, currentFontPointSize: 12, columns: 80, rows: 24)
        #expect(font == 9)
    }

    @Test func bothAxesUseTheSmallerFit() {
        let font = geometry(paneWidthPx: 640, paneHeightPx: 300, cellWidthPx: 10, cellHeightPx: 20)
            .targetFontPointSize(baseFontPointSize: 12, currentFontPointSize: 12, columns: 80, rows: 24)
        #expect(font == 7.5)
    }

    @Test func narrowPaneForMobileViewerShrinksBelowLegibilityFloor() {
        // A narrow Mac pane (e.g. a half-screen window) mirroring a wide phone in
        // landscape needs a sub-6pt runtime font to fit the phone's full column
        // grant. The Mac is not being read here — the viewer is on the phone — so
        // fitting must shrink past the old 6pt legibility floor to grant the
        // phone's full width instead of letterboxing it. 300px / (90 cols * 10px)
        // = 1/3, so the target is base(12) * 1/3 = 4pt, below the old floor.
        let font = geometry(paneWidthPx: 300, paneHeightPx: 10_000, cellWidthPx: 10, cellHeightPx: 20)
            .targetFontPointSize(baseFontPointSize: 12, currentFontPointSize: 12, columns: 90, rows: 24)
        #expect(font == 4)
    }

    @Test func floorClampAndPerAxisFallbackCapTheGrant() {
        let target = geometry(paneWidthPx: 300, paneHeightPx: 120, cellWidthPx: 10, cellHeightPx: 20)
            .targetFontPointSize(
                baseFontPointSize: 12,
                currentFontPointSize: 12,
                columns: 100,
                rows: 30,
                fontFloorPointSize: 8
            )
        let fallback = geometry(
            paneWidthPx: 300,
            paneHeightPx: 120,
            cellWidthPx: 10 * 8.0 / 12.0,
            cellHeightPx: 20 * 8.0 / 12.0
        ).cappedFallbackGrant(grantedColumns: 100, grantedRows: 30)
        #expect(target == 8)
        #expect(fallback.columns == 45)
        #expect(fallback.rows == 9)
        #expect(fallback.width <= 300)
        #expect(fallback.height <= 120)
    }

    @Test func paneGrowthMovesTargetBackTowardBase() {
        let small = geometry(paneWidthPx: 600, paneHeightPx: 600, cellWidthPx: 7.5, cellHeightPx: 15)
            .targetFontPointSize(baseFontPointSize: 12, currentFontPointSize: 9, columns: 80, rows: 24)
        let grown = geometry(paneWidthPx: 800, paneHeightPx: 600, cellWidthPx: 7.5, cellHeightPx: 15)
            .targetFontPointSize(baseFontPointSize: 12, currentFontPointSize: 9, columns: 80, rows: 24)
        #expect(small == 9)
        #expect(grown == 12)
    }

    @Test func convergenceGuardReportsOverflowOnly() {
        let geometry = geometry(paneWidthPx: 800, paneHeightPx: 500, cellWidthPx: 10, cellHeightPx: 20)
        #expect(geometry.needsRefinement(grantWidthPx: 801, grantHeightPx: 480))
        #expect(!geometry.needsRefinement(grantWidthPx: 800, grantHeightPx: 480))
    }

    @Test func smallOverflowUsesIntegerCellCorrectionBelowHysteresisBand() {
        let geometry = geometry(paneWidthPx: 795, paneHeightPx: 1000, cellWidthPx: 10, cellHeightPx: 20)
        let linearTarget = geometry.targetFontPointSize(
            baseFontPointSize: 12,
            currentFontPointSize: 12,
            columns: 80,
            rows: 24
        )
        let correctiveTarget = geometry.correctiveFontPointSizeForOverflow(
            currentFontPointSize: 12,
            columns: 80,
            rows: 24
        )
        #expect(abs(linearTarget - 12) < 0.25)
        #expect(abs(correctiveTarget - 10.8) < 0.001)
    }

    @Test func integerCellTargetIsFixedPointAtConvergedGeometry() {
        let currentFont: Float = 8.36
        let target = geometry(paneWidthPx: 795, paneHeightPx: 1000, cellWidthPx: 9, cellHeightPx: 18)
            .integerCellTargetFontPointSize(
                baseFontPointSize: 12,
                currentFontPointSize: currentFont,
                columns: 80,
                rows: 24
            )
        #expect(target == currentFont)
    }

    @Test func integerCellTargetGrowsBackAndClampsToBaseFont() {
        let target = geometry(paneWidthPx: 960, paneHeightPx: 1000, cellWidthPx: 9, cellHeightPx: 18)
            .integerCellTargetFontPointSize(
                baseFontPointSize: 10,
                currentFontPointSize: 8.36,
                columns: 80,
                rows: 24
            )
        #expect(target == 10)
    }

    @Test func paddingPixelsArePreserved() {
        let geometry = geometry(
            paneWidthPx: 825,
            paneHeightPx: 505,
            cellWidthPx: 10,
            cellHeightPx: 20,
            horizontalNonGridPixels: 25,
            verticalNonGridPixels: 25
        )
        let font = geometry.targetFontPointSize(
            baseFontPointSize: 12,
            currentFontPointSize: 12,
            columns: 80,
            rows: 24
        )
        let box = geometry.grantPixelBox(columns: 80, rows: 24)
        #expect(font == 12)
        #expect(box.width == 825)
        #expect(box.height == 505)
    }

    @Test func degenerateInputsReturnSafeValues() {
        let geometry = geometry(paneWidthPx: 0, paneHeightPx: -1, cellWidthPx: 0, cellHeightPx: -4)
        let font = geometry.targetFontPointSize(
            baseFontPointSize: 0,
            currentFontPointSize: -3,
            columns: 0,
            rows: -1
        )
        let box = geometry.grantPixelBox(columns: 0, rows: -1)
        #expect(font == 1)
        #expect(box.width == 1)
        #expect(box.height == 1)
    }

    private func geometry(
        paneWidthPx: Int,
        paneHeightPx: Int,
        cellWidthPx: Double,
        cellHeightPx: Double,
        horizontalNonGridPixels: Int = 0,
        verticalNonGridPixels: Int = 0
    ) -> MobileViewportFitGeometry {
        MobileViewportFitGeometry(
            paneWidthPx: paneWidthPx,
            paneHeightPx: paneHeightPx,
            cellWidthPx: cellWidthPx,
            cellHeightPx: cellHeightPx,
            horizontalNonGridPixels: horizontalNonGridPixels,
            verticalNonGridPixels: verticalNonGridPixels
        )
    }
}
