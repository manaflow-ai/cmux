import CmuxNextBrowser
import CoreGraphics
@testable import CmuxNextPopups
import Foundation
import Testing

/// Where a popup panel goes and how large it is, and the panel's strings,
/// which load from this module's Popups table.
struct BrowserPopupPanelGeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let opener = CGRect(x: 200, y: 100, width: 1000, height: 700)

    @Test func noSizeUsesTheDefaultContentCenteredOverTheOpener() {
        let frame = BrowserPopupPanelGeometry.frame(for: BrowserPopupRequest(), opener: opener, visibleFrame: screen,
                                                    primaryHeight: 900, titleHeight: 28)
        #expect(frame.size == CGSize(width: 500, height: 628))
        #expect(frame.midX == opener.midX)
        #expect(frame.midY == opener.midY)
    }

    @Test func aTinyRequestIsRaisedToTheMinimum() {
        let request = BrowserPopupRequest(size: CGSize(width: 10, height: 10))
        let frame = BrowserPopupPanelGeometry.frame(for: request, opener: opener, visibleFrame: screen, primaryHeight: 900, titleHeight: 28)
        #expect(frame.size == CGSize(width: 240, height: 188))
    }

    @Test func aPositionThatFitsIsMeasuredFromThePrimaryDisplaysTop() {
        let request = BrowserPopupRequest(size: CGSize(width: 400, height: 300), origin: CGPoint(x: 50, y: 60))
        let frame = BrowserPopupPanelGeometry.frame(for: request, opener: opener, visibleFrame: screen, primaryHeight: 900, titleHeight: 28)
        #expect(frame == CGRect(x: 50, y: 900 - 60 - 328, width: 400, height: 328))
    }

    @Test func aPositionOffScreenCentersInsideTheScreen() {
        let request = BrowserPopupRequest(size: CGSize(width: 400, height: 300), origin: CGPoint(x: 5000, y: 60))
        let frame = BrowserPopupPanelGeometry.frame(for: request, opener: opener, visibleFrame: screen, primaryHeight: 900, titleHeight: 28)
        #expect(screen.contains(frame))
        #expect(frame.midX == opener.midX)
    }

    @Test func theStringsLoadFromThisModulesTable() {
        #expect(PopupStrings.popupUntitled == "Popup")
        #expect(PopupStrings.popupCloseHelp == "Close Popup (Esc)")
    }
}
