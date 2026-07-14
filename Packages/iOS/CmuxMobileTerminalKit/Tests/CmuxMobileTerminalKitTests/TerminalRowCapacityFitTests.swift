import CoreGraphics
import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalRowCapacityFit")
struct TerminalRowCapacityFitTests {
    @Test("phone overlay transitions preserve a previously rendered full width")
    func phoneOverlayTransitionPreservesFullWidth() {
        let selected = TerminalColumnReportWidthSelection(
            currentWidth: 642,
            widestRenderedWidth: 1_032,
            preservesWidestRenderedWidth: true
        ).width

        #expect(selected == 1_032)
    }

    @Test("split panes report their current drawable width")
    func splitPaneUsesCurrentWidth() {
        let selected = TerminalColumnReportWidthSelection(
            currentWidth: 642,
            widestRenderedWidth: 1_032,
            preservesWidestRenderedWidth: false
        ).width

        #expect(selected == 642)
    }

    @Test("invalid report widths are rejected")
    func invalidReportWidthsAreRejected() {
        #expect(TerminalColumnReportWidthSelection(
            currentWidth: 0,
            widestRenderedWidth: 1_032,
            preservesWidestRenderedWidth: true
        ).width == nil)
        #expect(TerminalColumnReportWidthSelection(
            currentWidth: 642,
            widestRenderedWidth: 0,
            preservesWidestRenderedWidth: true
        ).width == nil)
    }

    @Test("column capacity normalizes stretched live cell width back to the base font")
    func columnCapacityNormalizesLiveFontToBaseFont() throws {
        let fit = try #require(TerminalRowCapacityFit(
            containerPixelHeight: 1_200,
            cellPixelHeight: 36,
            containerPixelWidth: 1_206,
            cellPixelWidth: 18,
            liveFontSize: 24
        ))

        #expect(fit.capacityColumns(atBaseFontSize: 12) == 134)
    }

    @Test("destination-font capacity is available before the live font changes")
    func destinationFontCapacityPrecedesFontChange() throws {
        let fit = try #require(TerminalRowCapacityFit(
            containerPixelHeight: 1_200,
            cellPixelHeight: 18,
            containerPixelWidth: 1_206,
            cellPixelWidth: 9,
            liveFontSize: 12
        ))

        #expect(fit.capacityColumns(atFontSize: 24) == 67)
        #expect(fit.capacityColumns(atFontSize: 0) == nil)
    }

    @Test("destination-font reporting follows fit hysteresis until font changes")
    func destinationFontReportingFollowsFitHysteresis() throws {
        let baseFit = try #require(TerminalRowCapacityFit(
            containerPixelHeight: 1_200,
            cellPixelHeight: 18,
            liveFontSize: 12
        ))
        let fitted = try #require(TerminalRowCapacityFit(
            containerPixelHeight: 1_200,
            cellPixelHeight: 21,
            liveFontSize: 14
        ))

        #expect(!baseFit.shouldReportDestinationFont(
            renderedRows: 50,
            effectiveRows: 49,
            baseFontSize: 12
        ))
        #expect(baseFit.shouldReportDestinationFont(
            renderedRows: 50,
            effectiveRows: 48,
            baseFontSize: 12
        ))
        #expect(fitted.shouldReportDestinationFont(
            renderedRows: 49,
            effectiveRows: 49,
            baseFontSize: 12
        ))
    }

    @Test("column capacity is the measured grid when live font equals base font")
    func columnCapacityIdentityAtBaseFont() throws {
        let fit = try #require(TerminalRowCapacityFit(
            containerPixelHeight: 1_200,
            cellPixelHeight: 18,
            containerPixelWidth: 1_206,
            cellPixelWidth: 9,
            liveFontSize: 12
        ))

        #expect(fit.capacityColumns(atBaseFontSize: 12) == 134)
    }

    @Test("horizontal cap returns the largest font that can render granted columns")
    func maximumFontSizeForEffectiveColumns() throws {
        let fit = try #require(TerminalRowCapacityFit(
            containerPixelHeight: 1_200,
            cellPixelHeight: 36,
            containerPixelWidth: 1_206,
            cellPixelWidth: 18,
            liveFontSize: 24
        ))

        let fullWidth = try #require(fit.maximumFontSize(forEffectiveColumns: 134, atBaseFontSize: 12))
        #expect(abs(fullWidth - 12) < 0.001)

        let halfWidth = try #require(fit.maximumFontSize(forEffectiveColumns: 67, atBaseFontSize: 12))
        #expect(abs(halfWidth - 24) < 0.001)
    }

    @Test("degenerate horizontal inputs return nil")
    func degenerateHorizontalInputsReturnNil() {
        #expect(TerminalRowCapacityFit(
            containerPixelHeight: 1_200,
            cellPixelHeight: 18,
            containerPixelWidth: 0,
            cellPixelWidth: 9,
            liveFontSize: 12
        )?.capacityColumns(atBaseFontSize: 12) == nil)
        #expect(TerminalRowCapacityFit(
            containerPixelHeight: 1_200,
            cellPixelHeight: 18,
            containerPixelWidth: 1_206,
            cellPixelWidth: 0,
            liveFontSize: 12
        )?.capacityColumns(atBaseFontSize: 12) == nil)

        let rowOnlyFit = TerminalRowCapacityFit(
            containerPixelHeight: 1_200,
            cellPixelHeight: 18,
            liveFontSize: 12
        )
        #expect(rowOnlyFit?.capacityColumns(atBaseFontSize: 12) == nil)
        #expect(rowOnlyFit?.maximumFontSize(forEffectiveColumns: 134, atBaseFontSize: 12) == nil)
        #expect(rowOnlyFit?.capacityColumns(atBaseFontSize: 0) == nil)
    }

    @Test("destination font waits for the exact viewport grant")
    func destinationFontWaitsForExactViewportGrant() {
        let request = TerminalViewportFontGrantRequest(
            fontSize: 24,
            reportColumns: 67,
            reportRows: 66,
            sourceEffectiveRows: 50
        )
        var state = TerminalViewportFontGrantState()

        #expect(state.decision(for: request) == .wait(requestNewReport: true))
        state.bindPendingRequest(toReportID: 7, columns: 67, rows: 66)

        #expect(state.consumeAcknowledgement(reportID: 6, columns: 67, rows: 50) == nil)
        #expect(state.consumeAcknowledgement(reportID: 7, columns: 68, rows: 50) == nil)
        #expect(state.consumeAcknowledgement(reportID: 7, columns: 67, rows: 49) == nil)
        #expect(state.consumeAcknowledgement(reportID: 7, columns: 67, rows: 50) == 24)
    }

    @Test("retry exhaustion keeps the safe font until geometry changes")
    func retryExhaustionKeepsSafeFontUntilGeometryChanges() {
        let failedRequest = TerminalViewportFontGrantRequest(
            fontSize: 24,
            reportColumns: 67,
            reportRows: 66,
            sourceEffectiveRows: 50
        )
        let changedRequest = TerminalViewportFontGrantRequest(
            fontSize: 20,
            reportColumns: 80,
            reportRows: 66,
            sourceEffectiveRows: 50
        )
        var state = TerminalViewportFontGrantState()

        #expect(state.decision(for: failedRequest) == .wait(requestNewReport: true))
        state.bindPendingRequest(toReportID: 7, columns: 67, rows: 66)
        state.noteReportFailure(reportID: 7, willRetry: true)
        #expect(state.decision(for: failedRequest) == .wait(requestNewReport: false))

        state.bindPendingRequest(toReportID: 8, columns: 67, rows: 66)
        state.noteReportFailure(reportID: 8, willRetry: false)
        #expect(state.decision(for: failedRequest) == .reject)
        #expect(state.decision(for: changedRequest) == .wait(requestNewReport: true))
    }
}
