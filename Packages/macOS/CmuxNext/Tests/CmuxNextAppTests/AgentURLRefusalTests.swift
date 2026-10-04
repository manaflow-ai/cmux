import CmuxNextBrowser
import CmuxNextControl
import Foundation
import Testing
@testable import CmuxNextApp

/// Agent page operations refuse Chromium's own pages before anything runs:
/// a navigate to one, a Back or Forward whose entry is one, and reload or
/// evaluate while the tab shows one (plans/cmux-next/passwords.md, section 2).
@MainActor @Suite struct AgentURLRefusalTests {
    func page(_ url: String? = "https://a.example/", kind: BrowserEngineKind = .cef) -> MockBrowserTab {
        MockBrowserEngine(kind: kind).makeMockTab(BrowserTabConfiguration(initialURL: url.flatMap(URL.init(string:))))
    }

    func list(_ urls: [String], current: Int) -> BrowserNavigationList {
        BrowserNavigationList(entries: urls.map { BrowserNavigationEntry(url: URL(string: $0), title: nil) }, current: current)
    }

    func refusal(_ operation: BrowserPageOperation, _ page: MockBrowserTab, target: String? = nil) -> ControlError? {
        AppBrowserPage.agentURLRefusal(operation, target: target.flatMap(URL.init(string:)), page: page)
    }

    @Test func navigateToAChromiumPageIsRefused() {
        let tab = page()
        for target in ["chrome://password-manager/passwords", "chrome-extension://abc/popup.html", "devtools://devtools/x", "chrome-untrusted://print/"] {
            #expect(refusal(.navigate(target), tab, target: target)?.code == "forbidden", "\(target)")
        }
        #expect(refusal(.navigate("https://b.example/"), tab, target: "https://b.example/") == nil)
    }

    @Test func evaluateAndReloadAreRefusedWhileTheTabShowsOne() {
        let shown = page("chrome://password-manager/passwords")
        #expect(refusal(.evaluate("1"), shown)?.code == "forbidden")
        #expect(refusal(.reload, shown)?.code == "forbidden")
        #expect(refusal(.state, shown) == nil, "state reads no page content")
        #expect(refusal(.evaluate("1"), page()) == nil)
    }

    @Test func theCurrentHistoryEntryCountsToo() {
        let tab = page()
        tab.navigation = list(["https://a.example/", "chrome://settings/"], current: 1)
        #expect(refusal(.evaluate("1"), tab)?.code == "forbidden")
    }

    @Test func backAndForwardIntoAChromiumPageAreRefused() {
        let tab = page()
        tab.navigation = list(["chrome://password-manager/passwords", "https://a.example/", "chrome-extension://abc/x.html"], current: 1)
        #expect(refusal(.back, tab)?.code == "forbidden")
        #expect(refusal(.forward, tab)?.code == "forbidden")
        tab.navigation = list(["https://z.example/", "https://a.example/", "https://b.example/"], current: 1)
        #expect(refusal(.back, tab) == nil)
        #expect(refusal(.forward, tab) == nil)
    }

    /// Without Chromium's list the target is unknown: a Chromium tab refuses;
    /// WebKit cannot load these pages at all.
    @Test func anUnknownHistoryTargetFailsClosedForChromium() {
        #expect(refusal(.back, page())?.code == "forbidden")
        #expect(refusal(.back, page(kind: .webkit)) == nil)
    }
}
