import Testing
@testable import CmuxNextBrowser

/// Who may give a Chromium page the keyboard, without starting CEF.
///
/// CEF focuses a page on its own after a navigation: the first load of a new
/// browser (the New Tab page) and every `LoadURL`. On macOS that activates
/// the page window, which then takes the keys from the new tab's omnibar
/// (dogfood nxdog13: desync W5 "a Chromium page window has the keys while
/// the model targets addressBar", 53 ms after the page attached, with no
/// focus request from cmux). Chrome keeps a new tab's omnibar focused until
/// the user clicks the page; in cmux only the focus coordinator moves focus.
@MainActor
@Suite struct CEFFocusRequestTests {
    private func makeTab() -> CEFTab {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "focus"), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        return tab
    }

    @Test func aNavigationNeverFocusesThePageOnItsOwn() {
        let tab = makeTab()
        #expect(!tab.chromiumRequestsFocus(.navigation))
    }

    @Test func chromiumNeverFocusesThePageOnItsOwn() {
        let tab = makeTab()
        #expect(!tab.chromiumRequestsFocus(.system))
    }
}
