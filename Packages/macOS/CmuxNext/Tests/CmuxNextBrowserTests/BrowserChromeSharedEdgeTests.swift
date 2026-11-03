import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// Review of #32909 step B (one chrome per pane): the edges of a shared chrome. A tab moved to another pane's chrome
/// leaves the first chrome with nothing of it and keeps what it showed; a closed tab's page is not held by the
/// chrome; a page that navigated while hidden shows design mode off; a cookie offer waits for its tab.
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserChromeSharedEdgeTests {
    static func tab(_ host: String) -> MockBrowserTab {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://\(host)/")))
        tab.load(URL(string: "https://\(host)/")!)
        return tab
    }

    static func window(_ chrome: BrowserChromeView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        chrome.frame = window.contentLayoutRect
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        return window
    }

    static func settle() async { for _ in 0..<8 { await Task.yield() } }

    /// A tab dragged to another pane: that pane's chrome takes it with what it showed, and the first chrome lets it go
    /// (no second render of it: one history visit per load, not two).
    @Test func aTabMovedToAnotherPanesChromeLeavesTheFirstChromeAndKeepsItsState() async {
        let t = Self.tab("t.example"), u = Self.tab("u.example")
        let stateT = BrowserChromeTabState(), stateU = BrowserChromeTabState()
        let paneA = BrowserPaneChrome(), paneB = BrowserPaneChrome()
        let chromeA = paneA.bind(t, state: stateT)
        let window = Self.window(chromeA)
        defer {
            window.close()
            paneA.drop()
            paneB.drop()
            t.close()
            u.close()
        }
        chromeA.addressBar.controller.send(.focusGained(.keyboard))
        chromeA.addressBar.controller.send(.fieldChanged(OmnibarInput.Field(text: "typed in A", selection: NSRange(location: 10, length: 0)), .insert))
        let chromeB = paneB.bind(t, state: stateT)
        let windowB = Self.window(chromeB)
        defer { windowB.close() }
        #expect(chromeA !== chromeB)
        #expect(chromeA.boundState == nil, "pane A's chrome no longer shows the moved tab")
        #expect(chromeA.tab !== t, "pane A's chrome no longer holds or watches the moved tab's page")
        #expect(t.contentView.superview === chromeB.contentContainer)
        #expect(chromeB.addressBar.displayedText == "typed in A", "the moved tab keeps the text left in its omnibar: \(chromeB.addressBar.displayedText)")
        paneA.bind(u, state: stateU)
        #expect(chromeA.tab === u)
    }

    /// The pane's shown tab closes: the chrome keeps nothing of it (its page is freed with its tab).
    @Test func aClosedTabsPageIsNotHeldByThePanesChrome() async {
        weak var closedPage: MockBrowserTab?
        let pane = BrowserPaneChrome()
        let other = Self.tab("other.example")
        defer {
            pane.drop()
            other.close()
        }
        autoreleasepool {
            let page = Self.tab("closed.example")
            closedPage = page
            let state = BrowserChromeTabState()
            pane.bind(page, state: state)
            BrowserTabRetirement(tab: page, state: state).retire()
        }
        await Self.settle()
        #expect(closedPage == nil, "the pane's chrome still holds the closed tab's page")
    }

    /// Design mode is per document: a tab that navigated while another tab showed comes back with it off.
    @Test func aPageThatNavigatedWhileHiddenShowsDesignModeOff() async {
        let t = Self.tab("t.example"), u = Self.tab("u.example")
        let stateT = BrowserChromeTabState(), stateU = BrowserChromeTabState()
        let pane = BrowserPaneChrome()
        let chrome = pane.bind(t, state: stateT)
        let window = Self.window(chrome)
        defer {
            window.close()
            pane.drop()
            t.close()
            u.close()
        }
        chrome.toolbarButtons.modes.designMode = true
        pane.bind(u, state: stateU)
        t.load(URL(string: "https://t.example/next")!)
        await Self.settle()
        pane.bind(t, state: stateT)
        await Self.settle()
        #expect(!chrome.toolbarButtons.modes.designMode, "design mode stayed on for a document that never had it")
    }

    /// The cookie import offer stays with its tab: a switch away and back shows it again (it shows once per launch).
    @Test func aCookieOfferComesBackWithItsTab() async {
        let t = Self.tab("t.example"), u = Self.tab("u.example")
        let stateT = BrowserChromeTabState(), stateU = BrowserChromeTabState()
        let pane = BrowserPaneChrome()
        let chrome = pane.bind(t, state: stateT)
        let window = Self.window(chrome)
        defer {
            window.close()
            pane.drop()
            t.close()
            u.close()
        }
        let offer = BrowserCookieImportOffer(icons: [], title: "Import", detail: "", importTitle: "Import", notNowTitle: "Not now")
        chrome.showCookieImportOffer(offer) { _ in }
        pane.bind(u, state: stateU)
        #expect(!chrome.showsCookieImportOffer)
        pane.bind(t, state: stateT)
        #expect(chrome.showsCookieImportOffer, "the offer left with the switch and never came back")
    }
}
