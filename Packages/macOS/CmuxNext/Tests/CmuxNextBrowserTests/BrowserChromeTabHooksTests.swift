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
}
