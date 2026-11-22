import Foundation
import Testing
import CmuxNextBrowser
import CmuxNextDaemon
@testable import CmuxNextApp

/// Chromium internal pages open in a Chromium tab from every new-tab path
/// (the page, newTab.submit, openBrowser): one rule.
@Suite struct ChromiumPageEngineTests {
    @Test(arguments: ["chrome://extensions/", "chrome-extension://abcdefghijklmnopabcdefghijklmnop/options.html", "CHROME://version/"])
    func chromiumPagesNeedChromium(_ address: String) {
        #expect(BrowserEngineTag.engine(for: URL(string: address)) == BrowserEngineTag.cef.rawValue)
    }

    @Test(arguments: ["https://example.com/", "about:blank", "file:///tmp/a.html"])
    func otherPagesLeaveTheDefault(_ address: String) {
        #expect(BrowserEngineTag.engine(for: URL(string: address)) == nil)
    }

    @Test func noURLLeavesTheDefault() {
        #expect(BrowserEngineTag.engine(for: nil) == nil)
    }

    @Test func newTabSubmitOpensChromiumPagesAsBrowserTabs() throws {
        let plan = NewTabSubmit.plan(text: "chrome://extensions", search: false, agent: nil, resolver: OmniboxResolver(),
                                     home: URL(filePath: "/Users/me"))
        #expect(plan == .browser(try #require(URL(string: "chrome://extensions/"))))
    }
}
