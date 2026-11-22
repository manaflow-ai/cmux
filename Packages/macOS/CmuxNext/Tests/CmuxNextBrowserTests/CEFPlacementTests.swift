import CoreGraphics
import Testing
@testable import CmuxNextBrowser

/// Bug (tagged build `incog`): `window.open(url, 'auth', 'width=480,height=640')`
/// opened its panel at the top-left corner of the opener's screen instead of
/// over the opener. The fork's window request always carries x and y (Chromium
/// fills in a default position), so a position the page never gave looked
/// like one it asked for.
@Suite struct CEFPlacementTests {
    @Test func aPositionThePageDidNotGiveIsNotUsed() {
        let request = CGRect(x: 2560, y: 25, width: 480, height: 640)
        // OnBeforePopup's features: x and y not set (0), size set.
        let created = CGRect(x: 0, y: 0, width: 480, height: 640)
        let bounds = CEFPlacement.resolvedBounds(request: request, created: created)
        #expect(BrowserPopupRequest(features: bounds) == BrowserPopupRequest(size: CGSize(width: 480, height: 640)))
    }

    @Test func aPositionThePageGaveIsKept() {
        let created = CGRect(x: 300, y: 200, width: 480, height: 640)
        let bounds = CEFPlacement.resolvedBounds(request: CGRect(x: 300, y: 200, width: 480, height: 640), created: created)
        #expect(BrowserPopupRequest(features: bounds).origin == CGPoint(x: 300, y: 200))
        // No renderer features (chrome.windows.create): the request's bounds.
        #expect(CEFPlacement.resolvedBounds(request: CGRect(x: 10, y: 20, width: 300, height: 200), created: nil)
            == CGRect(x: 10, y: 20, width: 300, height: 200))
    }
}
