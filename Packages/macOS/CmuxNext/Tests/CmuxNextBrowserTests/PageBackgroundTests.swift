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
}
