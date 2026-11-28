import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextBrowserCore

/// The link routing rules answered by Rust (cmux-browser-rules `link_routes.rs`) keep the answers the
/// Swift copies had.
@Suite struct BrowserLinkRulesFFITests {
    @Test func chromiumPagesNeedChromium() throws {
        #expect(ChromiumInternalURL.needsChromium(try #require(URL(string: "chrome://extensions/"))))
        #expect(ChromiumInternalURL.needsChromium(try #require(URL(string: "CHROME-EXTENSION://abc/page.html"))))
        #expect(!ChromiumInternalURL.needsChromium(try #require(URL(string: "https://example.com/"))))
        #expect(!ChromiumInternalURL.needsChromium(try #require(URL(string: "about:blank"))))
    }

    @Test func theNewTabPageAndTheBlankPageAreNewTabPages() throws {
        for text in ["about:blank", "ABOUT:BLANK", "chrome://newtab/", "chrome://newtab", "Chrome://NewTab/"] {
            #expect(BrowserNewTabPage.isNewTabPage(text), "\(text)")
        }
        #expect(!BrowserNewTabPage.isNewTabPage("https://example.com/"))
        #expect(!BrowserNewTabPage.isNewTabPage(""))
        #expect(!BrowserNewTabPage.isNewTabPage(nil as URL?))
        #expect(BrowserNewTabPage.isNewTabPage(try #require(URL(string: "about:blank"))))
    }

    @Test func aPopupTakesItsSizeAndANonZeroOrigin() {
        let placed = BrowserPopupRequest(features: CGRect(x: 10, y: 20, width: 400, height: 300))
        #expect(placed.size == CGSize(width: 400, height: 300))
        #expect(placed.origin == CGPoint(x: 10, y: 20))
        let unplaced = BrowserPopupRequest(features: CGRect(x: 0, y: 0, width: -5, height: 300))
        #expect(unplaced.size == CGSize(width: 0, height: 300))
        #expect(unplaced.origin == nil)
        #expect(BrowserPopupRequest(features: nil) == BrowserPopupRequest())
    }
}
