import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// One chrome per pane (#32909 step B): the host writes each tab's hooks and per-tab presentation to the tab's
/// `BrowserChromeTabState`, never to a chrome it does not show. The chrome that shows the tab runs that tab's
/// hooks only, and what a hidden tab was given (a notice, its bookmarks bar, its star) shows when it shows.
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserChromeTabHooksTests {
    static func tab(_ host: String) -> MockBrowserTab {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://\(host)/")))
        tab.load(URL(string: "https://\(host)/")!)
        return tab
    }

    static func shown(_ chrome: BrowserChromeView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        chrome.frame = window.contentLayoutRect
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        return window
    }

    @Test func theShownChromeRunsTheShownTabsHooksOnly() {
        let a = Self.tab("a.example"), b = Self.tab("b.example")
        let stateA = BrowserChromeTabState(), stateB = BrowserChromeTabState()
        var overrides: [String] = []
        stateA.loadOverride = { _ in overrides.append("a"); return true }
        stateB.loadOverride = { _ in overrides.append("b"); return true }
        stateA.tabKey = "tab-a"
        stateB.tabKey = "tab-b"
        let chrome = BrowserChromeView(tab: a)
        let window = Self.shown(chrome)
        defer {
            window.close()
            BrowserPageRetirement(tab: a, chrome: chrome).retire()
            b.close()
        }
        chrome.bind(a, state: stateA)
        _ = chrome.loadOverride?(URL(string: "https://x.example/")!)
        chrome.bind(b, state: stateB)
        _ = chrome.loadOverride?(URL(string: "https://x.example/")!)
        #expect(overrides == ["a", "b"])
        #expect(chrome.addressBar.tabKey == "tab-b")
        #expect(stateA.chrome == nil && stateB.chrome === chrome, "only the shown tab's state names the chrome")
    }

    @Test func aHiddenTabsNoticeStarAndBarShowWhenItShows() {
        let a = Self.tab("a.example"), b = Self.tab("b.example")
        let stateA = BrowserChromeTabState(), stateB = BrowserChromeTabState()
        let chrome = BrowserChromeView(tab: a)
        let window = Self.shown(chrome)
        defer {
            window.close()
            BrowserPageRetirement(tab: a, chrome: chrome).retire()
            b.close()
        }
        chrome.bind(a, state: stateA)
        let bar = NSView()
        stateB.showNotice("for b")
        stateB.bookmarkStar = .on
        stateB.accessory = (bar, 28)
        #expect(chrome.noticeText == nil, "a hidden tab's notice does not show on the tab that shows")
        #expect(chrome.accessoryView == nil)
        chrome.bind(b, state: stateB)
        #expect(chrome.noticeText == "for b")
        #expect(chrome.addressBar.bookmarkStarState == .on)
        #expect(chrome.accessoryView === bar)
        chrome.bind(a, state: stateA)
        #expect(chrome.noticeText == nil && chrome.accessoryView == nil, "tab A shows none of B's")
        #expect(stateB.noticeText == "for b", "B's notice waits for B")
    }

    /// A tab dragged to another pane brings the text left unsent in its omnibar, with its selection: the
    /// source chrome keeps the page's last draft for the tab on its state, the destination's page gets it
    /// with the slot, and the source page forgets the slot (a later return takes the state's draft).
    @Test func aTabMovedToAnotherPaneBringsItsOmnibarDraft() throws {
        let a = Self.tab("a.example"), c = Self.tab("c.example")
        let stateA = BrowserChromeTabState(), stateC = BrowserChromeTabState()
        let source = BrowserChromeView(tab: a), destination = BrowserChromeView(tab: c)
        let sourceWindow = Self.shown(source), destinationWindow = Self.shown(destination)
        defer {
            sourceWindow.close()
            destinationWindow.close()
            BrowserPageRetirement(tab: a, chrome: destination).retire()
            c.close()
        }
        source.bind(a, state: stateA)
        destination.bind(c, state: stateC)
        source.addressBar.handle(.status(OmnibarStatus(wire: [
            "phase": "editing", "editing": true, "text": "weather", "selection": [3, 2],
            "tab": stateA.slot, "draft": ["text": "weather", "selection": [3, 2]],
        ])))
        destination.bind(a, state: stateA)
        let draft = OmnibarDraft(text: "weather", selection: NSRange(location: 3, length: 2))
        #expect(stateA.omnibarDraft == draft)
        #expect(stateA.chrome === destination)
        let state = destination.addressBar.wireState()
        #expect(state["tab"] as? String == stateA.slot)
        let wired = try #require(state["draft"] as? [String: Any])
        #expect(wired["text"] as? String == "weather")
        #expect(wired["selection"] as? [Int] == [3, 2])
        let events = (source.addressBar.wireState()["events"] as? [[String: Any]] ?? []).compactMap { $0["event"] as? [String: Any] }
        #expect(events.contains { $0["kind"] as? String == "forgetTab" && $0["tab"] as? String == stateA.slot },
                "the source page forgets the moved tab's slot")
    }
}
