import Foundation
import Testing
@testable import CmuxNextBrowser

/// A redirect, an opener, a history step or a restored entry can still
/// commit a Chromium page in an agent-driven tab; the tab leaves it at once
/// (plans/cmux-next/passwords.md, section 2).
@MainActor @Suite struct CEFAgentURLGuardTests {
    private func makeTab() -> CEFTab {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "t"), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        return tab
    }

    private func commit(_ tab: CEFTab, _ url: String) {
        tab.handle(.loadingState(browser: 1, loading: true, canGoBack: true, canGoForward: false))
        tab.handle(.loadStart(browser: 1, url: url))
    }

    @Test func anAgentDrivenTabLeavesACommittedChromiumPage() {
        let tab = makeTab()
        tab.markAgentDriven()
        commit(tab, "https://a.example/")
        commit(tab, "chrome://password-manager/passwords")
        #expect(tab.state.url?.absoluteString == "about:blank")
    }

    @Test func anAddressChangeToAChromiumPageIsLeftToo() {
        let tab = makeTab()
        tab.markAgentDriven()
        commit(tab, "https://a.example/")
        tab.handle(.address(browser: 1, url: "chrome-extension://abc/popup.html"))
        #expect(tab.state.url?.absoluteString == "about:blank")
    }

    @Test func aTabShowingAChromiumPageLeavesItWhenAnAgentTakesIt() {
        let tab = makeTab()
        commit(tab, "chrome://settings/passwords")
        #expect(tab.state.url?.absoluteString == "chrome://settings/passwords", "a person may use Chromium's pages")
        tab.markAgentDriven()
        #expect(tab.state.url?.absoluteString == "about:blank")
    }

    @Test func aPersonsTabKeepsChromiumPages() {
        let tab = makeTab()
        commit(tab, "chrome://extensions/")
        #expect(tab.state.url?.absoluteString == "chrome://extensions/")
    }

    /// The first navigation starts at browser creation, before the shim
    /// guard is set: an agent-driven tab is created on about:blank instead.
    @Test func anAgentDrivenTabIsNeverCreatedOnAChromiumPage() throws {
        let tab = makeTab()
        tab.markAgentDriven()
        tab.load(try #require(URL(string: "chrome://password-manager/passwords")))
        #expect(tab.initialURLString == "about:blank")

        let person = makeTab()
        person.load(try #require(URL(string: "chrome://extensions/")))
        #expect(person.initialURLString == "chrome://extensions/")
    }
}
