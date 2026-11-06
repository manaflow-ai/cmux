import CoreGraphics
import Testing
@testable import CmuxMobileTerminalKit

@Suite struct TerminalColumnReportWidthHistoryTests {
    @Test func regularSplitPaneShrinksWithoutWindowResize() {
        var history = TerminalColumnReportWidthHistory()
        let window = CGSize(width: 1_032, height: 800)
        #expect(history.width(currentWidth: 1_032, windowSize: window, isCompactLayout: false) == 1_032)
        #expect(history.width(currentWidth: 642, windowSize: window, isCompactLayout: false) == 642)
    }

    @Test func compactOverlayRetainsRenderedWidth() {
        var history = TerminalColumnReportWidthHistory()
        let window = CGSize(width: 440, height: 900)
        #expect(history.width(currentWidth: 440, windowSize: window, isCompactLayout: true) == 440)
        #expect(history.width(currentWidth: 300, windowSize: window, isCompactLayout: true) == 440)
    }

    @Test func foldAndUnfoldResetHistory() {
        var history = TerminalColumnReportWidthHistory()
        #expect(history.width(currentWidth: 700, windowSize: .init(width: 1_032, height: 800), isCompactLayout: false) == 700)
        #expect(history.width(currentWidth: 380, windowSize: .init(width: 380, height: 800), isCompactLayout: true) == 380)
        #expect(history.width(currentWidth: 642, windowSize: .init(width: 1_032, height: 800), isCompactLayout: false) == 642)
    }

    @Test func layoutModeChangeResetsOverlayHistory() {
        var history = TerminalColumnReportWidthHistory()
        let window = CGSize(width: 900, height: 700)
        _ = history.width(currentWidth: 900, windowSize: window, isCompactLayout: true)
        #expect(history.width(currentWidth: 540, windowSize: window, isCompactLayout: false) == 540)
        #expect(history.width(currentWidth: 540, windowSize: window, isCompactLayout: true) == 540)
    }
}
