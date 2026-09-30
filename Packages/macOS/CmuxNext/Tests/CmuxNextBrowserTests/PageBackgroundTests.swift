import Foundation
import Testing
@testable import CmuxNextBrowser

/// A popup (or a tab a page opened) with no background of its own showed
/// dark text on the dark theme color: the page commits before cmux adopts
/// it, so the "first real page" switch to Chromium's white never ran. The
/// theme color is only for a new tab before its first paint.
@Suite struct PageBackgroundTests {
    @Test func aPageOpenedByAPageUsesTheEngineDefault() {
        #expect(!PageBackground.startsWithTheme(openedByPage: true))
        #expect(PageBackground.startsWithTheme(openedByPage: false))
    }

    @Test func blankURLs() {
        #expect(PageBackground.isBlank(nil))
        #expect(PageBackground.isBlank(URL(string: "about:blank")))
        // A new Chromium tab opens the New Tab page: blank, no URL in the omnibar.
        #expect(PageBackground.isBlank(URL(string: "chrome://newtab/")))
        #expect(BrowserURLDisplay.displayText(for: URL(string: "chrome://newtab/")) == "")
        #expect(!PageBackground.isBlank(URL(string: "https://example.com")))
    }
}
