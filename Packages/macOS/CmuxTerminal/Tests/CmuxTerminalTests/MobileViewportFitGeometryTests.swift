import Testing

@testable import CmuxTerminal

@Suite("Mobile viewport fit geometry")
struct MobileViewportFitGeometryTests {
    @Test func fitNotNeededKeepsBaseFontAndGrantBox() {
        let font = MobileViewportFitGeometry.targetFontPointSize(
            paneWidthPx: 1000,
            paneHeightPx: 600,
            measuredCellWidthPx: 10,
            measuredCellHeightPx: 20,
            baseFontPointSize: 12,
            currentFontPointSize: 12,
            columns: 80,
            rows: 24,
            horizontalNonGridPixels: 0,
            verticalNonGridPixels: 0
        )
        let box = MobileViewportFitGeometry.grantPixelBox(
            columns: 80,
            rows: 24,
            cellWidthPx: 10,
            cellHeightPx: 20,
            horizontalNonGridPixels: 0,
            verticalNonGridPixels: 0
        )
        #expect(font == 12)
        #expect(box.width == 800)
        #expect(box.height == 480)
    }

    @Test func widthConstrainedGrantShrinksFont() {
        let font = MobileViewportFitGeometry.targetFontPointSize(
            paneWidthPx: 600,
            paneHeightPx: 600,
            measuredCellWidthPx: 10,
            measuredCellHeightPx: 20,
            baseFontPointSize: 12,
            currentFontPointSize: 12,
            columns: 80,
            rows: 24,
            horizontalNonGridPixels: 0,
            verticalNonGridPixels: 0
        )
        #expect(font == 9)
    }

    @Test func heightConstrainedGrantShrinksFont() {
        let font = MobileViewportFitGeometry.targetFontPointSize(
            paneWidthPx: 1000,
            paneHeightPx: 360,
            measuredCellWidthPx: 10,
            measuredCellHeightPx: 20,
            baseFontPointSize: 12,
            currentFontPointSize: 12,
            columns: 80,
            rows: 24,
            horizontalNonGridPixels: 0,
            verticalNonGridPixels: 0
        )
        #expect(font == 9)
    }

    @Test func bothAxesUseTheSmallerFit() {
        let font = MobileViewportFitGeometry.targetFontPointSize(
            paneWidthPx: 640,
            paneHeightPx: 300,
            measuredCellWidthPx: 10,
            measuredCellHeightPx: 20,
            baseFontPointSize: 12,
            currentFontPointSize: 12,
            columns: 80,
            rows: 24,
            horizontalNonGridPixels: 0,
            verticalNonGridPixels: 0
        )
        #expect(font == 7.5)
    }

    @Test func floorClampAndPerAxisFallbackCapTheGrant() {
        let target = MobileViewportFitGeometry.targetFontPointSize(
            paneWidthPx: 300,
            paneHeightPx: 120,
            measuredCellWidthPx: 10,
            measuredCellHeightPx: 20,
            baseFontPointSize: 12,
            currentFontPointSize: 12,
            columns: 100,
            rows: 30,
            horizontalNonGridPixels: 0,
            verticalNonGridPixels: 0,
            fontFloorPointSize: 8
        )
        let fallback = MobileViewportFitGeometry.cappedFallbackGrant(
            grantedColumns: 100,
            grantedRows: 30,
            paneWidthPx: 300,
            paneHeightPx: 120,
            cellWidthPxAtFloor: 10 * 8.0 / 12.0,
            cellHeightPxAtFloor: 20 * 8.0 / 12.0,
            horizontalNonGridPixels: 0,
            verticalNonGridPixels: 0
        )
        #expect(target == 8)
        #expect(fallback.columns == 45)
        #expect(fallback.rows == 9)
        #expect(fallback.width <= 300)
        #expect(fallback.height <= 120)
    }

    @Test func paneGrowthMovesTargetBackTowardBase() {
        let small = MobileViewportFitGeometry.targetFontPointSize(
            paneWidthPx: 600,
            paneHeightPx: 600,
            measuredCellWidthPx: 7.5,
            measuredCellHeightPx: 15,
            baseFontPointSize: 12,
            currentFontPointSize: 9,
            columns: 80,
            rows: 24,
            horizontalNonGridPixels: 0,
            verticalNonGridPixels: 0
        )
        let grown = MobileViewportFitGeometry.targetFontPointSize(
            paneWidthPx: 800,
            paneHeightPx: 600,
            measuredCellWidthPx: 7.5,
            measuredCellHeightPx: 15,
            baseFontPointSize: 12,
            currentFontPointSize: 9,
            columns: 80,
            rows: 24,
            horizontalNonGridPixels: 0,
            verticalNonGridPixels: 0
        )
        #expect(small == 9)
        #expect(grown == 12)
    }

    @Test func convergenceGuardReportsOverflowOnly() {
        #expect(MobileViewportFitGeometry.needsRefinement(
            grantWidthPx: 801,
            grantHeightPx: 480,
            paneWidthPx: 800,
            paneHeightPx: 500
        ))
        #expect(!MobileViewportFitGeometry.needsRefinement(
            grantWidthPx: 800,
            grantHeightPx: 480,
            paneWidthPx: 800,
            paneHeightPx: 500
        ))
    }

    @Test func smallOverflowUsesIntegerCellCorrectionBelowHysteresisBand() {
        let linearTarget = MobileViewportFitGeometry.targetFontPointSize(
            paneWidthPx: 795,
            paneHeightPx: 1000,
            measuredCellWidthPx: 10,
            measuredCellHeightPx: 20,
            baseFontPointSize: 12,
            currentFontPointSize: 12,
            columns: 80,
            rows: 24,
            horizontalNonGridPixels: 0,
            verticalNonGridPixels: 0
        )
        let correctiveTarget = MobileViewportFitGeometry.correctiveFontPointSizeForOverflow(
            paneWidthPx: 795,
            paneHeightPx: 1000,
            measuredCellWidthPx: 10,
            measuredCellHeightPx: 20,
            currentFontPointSize: 12,
            columns: 80,
            rows: 24,
            horizontalNonGridPixels: 0,
            verticalNonGridPixels: 0
        )
        #expect(abs(linearTarget - 12) < 0.25)
        #expect(abs(correctiveTarget - 10.8) < 0.001)
    }

    @Test func integerCellTargetIsFixedPointAtConvergedGeometry() {
        let currentFont: Float = 8.36
        let target = MobileViewportFitGeometry.integerCellTargetFontPointSize(
            paneWidthPx: 795,
            paneHeightPx: 1000,
            measuredCellWidthPx: 9,
            measuredCellHeightPx: 18,
            baseFontPointSize: 12,
            currentFontPointSize: currentFont,
            columns: 80,
            rows: 24,
            horizontalNonGridPixels: 0,
            verticalNonGridPixels: 0
        )
        #expect(target == currentFont)
    }

    @Test func integerCellTargetGrowsBackAndClampsToBaseFont() {
        let target = MobileViewportFitGeometry.integerCellTargetFontPointSize(
            paneWidthPx: 960,
            paneHeightPx: 1000,
            measuredCellWidthPx: 9,
            measuredCellHeightPx: 18,
            baseFontPointSize: 10,
            currentFontPointSize: 8.36,
            columns: 80,
            rows: 24,
            horizontalNonGridPixels: 0,
            verticalNonGridPixels: 0
        )
        #expect(target == 10)
    }

    @Test func paddingPixelsArePreserved() {
        let font = MobileViewportFitGeometry.targetFontPointSize(
            paneWidthPx: 825,
            paneHeightPx: 505,
            measuredCellWidthPx: 10,
            measuredCellHeightPx: 20,
            baseFontPointSize: 12,
            currentFontPointSize: 12,
            columns: 80,
            rows: 24,
            horizontalNonGridPixels: 25,
            verticalNonGridPixels: 25
        )
        let box = MobileViewportFitGeometry.grantPixelBox(
            columns: 80,
            rows: 24,
            cellWidthPx: 10,
            cellHeightPx: 20,
            horizontalNonGridPixels: 25,
            verticalNonGridPixels: 25
        )
        #expect(font == 12)
        #expect(box.width == 825)
        #expect(box.height == 505)
    }

    @Test func degenerateInputsReturnSafeValues() {
        let font = MobileViewportFitGeometry.targetFontPointSize(
            paneWidthPx: 0,
            paneHeightPx: -1,
            measuredCellWidthPx: 0,
            measuredCellHeightPx: -4,
            baseFontPointSize: 0,
            currentFontPointSize: -3,
            columns: 0,
            rows: -1,
            horizontalNonGridPixels: -2,
            verticalNonGridPixels: -2
        )
        let box = MobileViewportFitGeometry.grantPixelBox(
            columns: 0,
            rows: -1,
            cellWidthPx: 0,
            cellHeightPx: -4,
            horizontalNonGridPixels: -2,
            verticalNonGridPixels: -2
        )
        #expect(font == 1)
        #expect(box.width == 1)
        #expect(box.height == 1)
    }
}
