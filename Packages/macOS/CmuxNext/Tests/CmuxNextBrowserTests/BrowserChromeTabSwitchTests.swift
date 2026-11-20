import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// One chrome per pane (lead decision 2026-11-03, #32909 step B, Chrome's model): a pane's browser tabs
/// share one `BrowserChromeView`, and a tab switch rebinds it. Each tab's own toolbar state comes back
/// exactly when it shows again: the omnibar text left there, the find pill and its query, design mode,
/// the hidden omnibar row; and its page stays in the window, hidden, so the switch moves no window.
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserChromeTabSwitchTests {
    struct Pane {
        let window: NSWindow
        let chrome: BrowserChromeView
        let a: MockBrowserTab, b: MockBrowserTab
        let stateA = BrowserChromeTabState(), stateB = BrowserChromeTabState()

        init() {
            a = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://a.example/")))
            b = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://b.example/")))
            a.load(URL(string: "https://a.example/")!)
            b.load(URL(string: "https://b.example/")!)
            chrome = BrowserChromeView(tab: a)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            chrome.frame = window.contentLayoutRect
            window.contentView = chrome
            chrome.bind(a, state: stateA)
            chrome.layoutSubtreeIfNeeded()
        }

        func show(_ tab: MockBrowserTab) async {
            chrome.bind(tab, state: tab === a ? stateA : stateB)
            chrome.layoutSubtreeIfNeeded()
            for _ in 0..<8 { await Task.yield() }
        }

        func tearDown() {
            window.close()
            BrowserPageRetirement(tab: a, chrome: chrome).retire()
            b.close()
        }
    }

    @Test func theOmnibarTextLeftInATabComesBackWithIt() async {
        let pane = Pane()
        defer { pane.tearDown() }
        await pane.show(pane.a)
        let bar = pane.chrome.addressBar
        bar.controller.send(.focusGained(.keyboard))
        bar.controller.send(.fieldChanged(OmnibarInput.Field(text: "half typed", selection: NSRange(location: 10, length: 0)), .insert))
        await pane.show(pane.b)
        #expect(!bar.displayedText.contains("half typed"), "tab B shows its own address, not A's typing: \(bar.displayedText)")
        await pane.show(pane.a)
        #expect(bar.displayedText == "half typed", "tab A's typing came back: \(bar.displayedText)")
    }

    @Test func theFindPillAndItsQueryComeBackWithTheirTab() async {
        let pane = Pane()
        defer { pane.tearDown() }
        await pane.show(pane.a)
        pane.chrome.showFindBar()
        pane.chrome.findBar.pill.query = "needle"
        await pane.show(pane.b)
        #expect(pane.chrome.shownFindBar == nil, "tab B has no find pill")
        await pane.show(pane.a)
        #expect(pane.chrome.shownFindBar?.pill.query == "needle", "tab A's find pill and query came back")
    }

    @Test func designModeAndTheHiddenOmnibarArePerTab() async {
        let pane = Pane()
        defer { pane.tearDown() }
        await pane.show(pane.a)
        pane.chrome.toolbarButtons.modes.designMode = true
        pane.chrome.isOmnibarHidden = true
        await pane.show(pane.b)
        #expect(!pane.chrome.toolbarButtons.modes.designMode, "design mode is tab A's")
        #expect(!pane.chrome.isOmnibarHidden, "the hidden omnibar row is tab A's")
        await pane.show(pane.a)
        #expect(pane.chrome.toolbarButtons.modes.designMode)
        #expect(pane.chrome.isOmnibarHidden)
    }

    @Test func aSwitchKeepsTheOtherPageInTheWindowHidden() async {
        let pane = Pane()
        defer { pane.tearDown() }
        await pane.show(pane.b)
        #expect(pane.a.contentView.window === pane.window, "tab A's page stayed in the window: no child-window re-add on the way back")
        #expect(pane.a.contentView.isHidden)
        await pane.show(pane.a)
        #expect(!pane.a.contentView.isHidden && pane.b.contentView.isHidden)
        let pinned = pane.chrome.contentContainer.constraints.filter { $0.firstItem === pane.a.contentView || $0.secondItem === pane.a.contentView }
        #expect(pinned.count == 4, "the page is pinned to the page area once, not once per switch: \(pinned.count)")
    }
}
