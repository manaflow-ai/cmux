import CoreGraphics
import Testing

@testable import CmuxBrowser

/// The part of a divider's grab band over a Chromium page opens a hole only
/// while the pointer is in it.
@Suite struct ChromiumDividerBandsTests {
    /// Two side-by-side panes, the right one a Chromium page at x 300...600;
    /// the divider's line at x 300 with an 8 pt grab area on each side.
    private let page = CGRect(x: 300, y: 0, width: 300, height: 400)
    private let divider = ChromiumDividerBands.Divider(hitRect: CGRect(x: 292, y: 0, width: 17, height: 400),
                                                       isVertical: true)

    @Test func thePartOverThePageUnderThePointerIsTheBand() {
        let band = ChromiumDividerBands.band(at: CGPoint(x: 304, y: 200), pages: [page], dividers: [divider])
        #expect(band == ChromiumDividerBands.Band(rect: CGRect(x: 300, y: 0, width: 9, height: 400), isVertical: true))
    }

    @Test func noBandAwayFromTheDividerOrBesideThePage() {
        // Inside the page, past the grab area.
        #expect(ChromiumDividerBands.band(at: CGPoint(x: 320, y: 200), pages: [page], dividers: [divider]) == nil)
        // In the grab area, but over the left (non-Chromium) pane.
        #expect(ChromiumDividerBands.band(at: CGPoint(x: 295, y: 200), pages: [page], dividers: [divider]) == nil)
    }

    @Test func aHorizontalDividerAboveAPageGivesARowBand() {
        let lower = CGRect(x: 0, y: 0, width: 600, height: 200)
        let row = ChromiumDividerBands.Divider(hitRect: CGRect(x: 0, y: 192, width: 600, height: 17), isVertical: false)
        let band = ChromiumDividerBands.band(at: CGPoint(x: 100, y: 195), pages: [lower], dividers: [row])
        #expect(band == ChromiumDividerBands.Band(rect: CGRect(x: 0, y: 192, width: 600, height: 8), isVertical: false))
    }
}
