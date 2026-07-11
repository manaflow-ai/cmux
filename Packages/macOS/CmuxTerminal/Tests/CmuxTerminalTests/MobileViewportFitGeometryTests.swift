import Testing

@testable import CmuxTerminal

@Suite("Mobile viewport fit geometry")
struct MobileViewportFitGeometryTests {
    @Test func destinationScaleProjectsMeasuredCellsAndPadding() {
        let projection = MobileViewportScaleProjection(
            currentXScale: 1,
            currentYScale: 1,
            destinationXScale: 2,
            destinationYScale: 1.5
        )

        #expect(projection.cellWidth(10) == 20)
        #expect(projection.cellHeight(20) == 30)
        #expect(projection.horizontalNonGridPixels(4) == 8)
        #expect(projection.verticalNonGridPixels(4) == 6)
    }

    @Test func explicitZoomReplacesTheCachedAutomaticFitBaseline() {
        var state = MobileViewportFontFitState(
            baseFontPointSize: 12,
            fittedFontPointSize: 8,
            baseWasUserAdjusted: false
        )

        state.reconcile(liveFontPointSize: 9, configuredFontPointSize: 12)

        #expect(state.baseFontPointSize == 9)
        #expect(state.fittedFontPointSize == nil)
        #expect(state.baseWasUserAdjusted == true)
        #expect(state.resolvedCurrentFontPointSize(liveFontPointSize: 9) == 9)
    }

    @Test func explicitZoomReplacesAnUnfittedCachedBaseline() {
        var state = MobileViewportFontFitState(
            baseFontPointSize: 12,
            fittedFontPointSize: nil,
            baseWasUserAdjusted: false
        )

        state.reconcile(liveFontPointSize: 14, configuredFontPointSize: 12)

        #expect(state.baseFontPointSize == 14)
        #expect(state.baseWasUserAdjusted == true)
    }

    @Test func liveFontProbeRunsOnceUntilCellMetricsSignalAChange() {
        var state = MobileViewportFontFitState()

        let initialRequest = state.consumeLiveFontProbeRequest()
        let steadyStateRequest = state.consumeLiveFontProbeRequest()
        #expect(initialRequest)
        #expect(!steadyStateRequest)

        state.cellMetricsDidChange()

        let signaledRequest = state.consumeLiveFontProbeRequest()
        let nextSteadyStateRequest = state.consumeLiveFontProbeRequest()
        #expect(signaledRequest)
        #expect(!nextSteadyStateRequest)
    }

    @Test func activeRuntimeConfigWinsWhenSurfaceHasNoTemplateFont() {
        let resolved = MobileViewportResetFontPointSize.resolve(
            runtimeConfigFontPointSize: 16,
            fallbackBaseFontPointSize: 12,
            magnificationPercent: 100
        )

        #expect(resolved == 16)
    }

    @Test func activeRuntimeConfigDefinesResetTargetForInheritedTemplateFont() {
        let configured = MobileViewportResetFontPointSize.resolve(
            runtimeConfigFontPointSize: 12,
            fallbackBaseFontPointSize: 12,
            magnificationPercent: 100
        )
        var state = MobileViewportFontFitState()
        state.begin(baseFontPointSize: 14, configuredFontPointSize: configured)
        state.recordFittedFontPointSize(9)

        #expect(state.baseWasUserAdjusted == true)
        #expect(state.restorePlan(configuredFontPointSize: configured) == .resetThenSet(14))
    }

    @Test func configuredBaselineTracksConfigChangesDuringAutomaticFit() {
        var state = MobileViewportFontFitState(
            baseFontPointSize: 12,
            fittedFontPointSize: 8,
            baseWasUserAdjusted: false
        )

        state.reconcile(liveFontPointSize: 8, configuredFontPointSize: 14)

        #expect(state.baseFontPointSize == 14)
        #expect(state.fittedFontPointSize == 8)
    }

    @Test func restoreClearsAutomaticAdjustmentButPreservesUserAdjustment() {
        let automatic = MobileViewportFontFitState(
            baseFontPointSize: 12,
            fittedFontPointSize: 8,
            baseWasUserAdjusted: false
        )
        let userAdjusted = MobileViewportFontFitState(
            baseFontPointSize: 14,
            fittedFontPointSize: 9,
            baseWasUserAdjusted: true
        )

        #expect(automatic.restorePlan(configuredFontPointSize: 12) == .resetToConfigured)
        #expect(userAdjusted.restorePlan(configuredFontPointSize: 12) == .resetThenSet(14))
    }

    @Test func reloadRefitPreservesUserAdjustedFontOwnership() {
        var state = MobileViewportFontFitState()

        state.begin(
            baseFontPointSize: 14,
            configuredFontPointSize: 14,
            preservedUserAdjustedBaseFontPointSize: 14
        )
        state.recordFittedFontPointSize(9)
        state.reconcile(liveFontPointSize: 9, configuredFontPointSize: 12)

        #expect(state.baseFontPointSize == 14)
        #expect(state.baseWasUserAdjusted == true)
        #expect(state.restorePlan(configuredFontPointSize: 12) == .resetThenSet(14))
    }

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
