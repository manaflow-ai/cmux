import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Testing

/// One chrome per pane (#32909 step B, Chrome's model): a pane's browser tabs share one `BrowserChromeView`. A browser
/// tab opened in a pane that has one builds no chrome view, a switch rebinds that one chrome, and a tab's page leaves
/// the chrome when the tab closes while the chrome stays for the pane's other tabs.
@MainActor @Suite(.serialized, .closesItsWindows) struct PaneBrowserChromeSharedTests {
    static func entry(_ host: String) -> BrowserEntry {
        let page = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://\(host)/")))
        page.load(URL(string: "https://\(host)/")!)
        return BrowserEntry(tab: page)
    }

    @Test func aSecondBrowserTabInAPaneBuildsNoChrome() {
        let pane = BrowserPaneChrome()
        defer { pane.drop() }
        let a = Self.entry("a.example"), b = Self.entry("b.example")
        let first = pane.bind(a.tab, state: a.state)
        let second = pane.bind(b.tab, state: b.state)
        #expect(first === second, "the pane's second browser tab shows in the chrome its first made")
        #expect(a.chrome == nil && b.chrome === second, "only the shown tab's state names the chrome")
        #expect(pane.bind(a.tab, state: a.state) === first, "a switch back rebinds the same chrome")
        #expect(first.tab === a.tab)
    }

    @Test func closingTheShownTabKeepsTheChromeForTheOthers() {
        let pane = BrowserPaneChrome()
        defer { pane.drop() }
        let a = Self.entry("a.example"), b = Self.entry("b.example")
        let chrome = pane.bind(a.tab, state: a.state)
        _ = pane.bind(b.tab, state: b.state)
        b.close()
        #expect(b.tab.contentView.superview == nil, "the closed tab's page left the chrome")
        #expect(chrome.boundState == nil, "the chrome shows no tab until the pane binds the next")
        #expect(pane.bind(a.tab, state: a.state) === chrome && chrome.tab === a.tab)
        #expect(!a.tab.contentView.isHidden, "the remaining tab's page shows")
    }
}
