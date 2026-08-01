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
}
