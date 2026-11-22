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

    /// Coordinator decision 2026-09-30 (both engines): the
    /// theme color shows only before a tab's first real page; after it, a
    /// Chromium page without a background of its own is white, popups and
    /// moved tabs included.
    @Test func chromiumIsWhiteAfterTheFirstRealPage() {
        let theme: UInt32 = 0xFF1E_1E1E
        #expect(PageBackground.chromiumARGB(pastFirstRealPage: false, theme: theme) == theme)
        #expect(PageBackground.chromiumARGB(pastFirstRealPage: true, theme: theme) == PageBackground.engineDefaultARGB)
        #expect(PageBackground.isRealPage(URL(string: "https://example.com/")))
        #expect(!PageBackground.isRealPage(URL(string: "about:blank")))
        #expect(!PageBackground.isRealPage(URL(string: "chrome://newtab/")))
        #expect(!PageBackground.isRealPage(nil))
    }
}
