import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// A new tab whose page comes a frame later keeps the pane's chrome showing (`BrowserChromeView.awaitNewTab`): the
/// toolbar row stays with an empty address and no page, the leaving tab keeps its state and page (hidden), and the
/// next bind shows the new tab, or the same tab again. In-tree sweep D8: ten Cmd-Shift-L at 80 ms showed the pane with
/// no content, its toolbar row gone, for 28-34 frames.
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserChromeAwaitingTabTests {
    @Test func aNewTabsWaitKeepsTheToolbarWithAnEmptyAddressAndHidesTheLeavingPage() async {
        let a = BrowserChromeSharedEdgeTests.tab("a.example"), b = BrowserChromeSharedEdgeTests.tab("b.example")
        let stateA = BrowserChromeTabState(), stateB = BrowserChromeTabState()
        let pane = BrowserPaneChrome()
        let chrome = pane.bind(a, state: stateA)
        let window = BrowserChromeSharedEdgeTests.window(chrome)
        defer { window.close(); pane.drop(); a.close(); b.close() }
        await BrowserChromeSharedEdgeTests.settle()
        chrome.addressBar.controller.send(.focusGained(.keyboard))
        chrome.addressBar.controller.send(.fieldChanged(OmnibarInput.Field(text: "typed in A", selection: NSRange(location: 10, length: 0)), .insert))

        chrome.awaitNewTab()
        #expect(chrome.isAwaitingTab)
        #expect(!chrome.isHidden && chrome.superview != nil, "the chrome, its toolbar row with it, stays shown")
        #expect(chrome.addressBar.displayedText.isEmpty, "the waiting tab's address is empty, not A's: \(chrome.addressBar.displayedText)")
        #expect(a.contentView.isHidden && a.contentView.superview === chrome.contentContainer, "A's page waits hidden in place")

        pane.bind(b, state: stateB)
        #expect(!chrome.isAwaitingTab)
        #expect(chrome.tab === b && !b.contentView.isHidden)
        #expect(a.contentView.isHidden && a.contentView.superview === chrome.contentContainer, "A's page stays parked")

        pane.bind(a, state: stateA)
        #expect(chrome.addressBar.displayedText == "typed in A", "A keeps what it left in its omnibar: \(chrome.addressBar.displayedText)")
        #expect(!a.contentView.isHidden)
    }

    @Test func theSameTabAgainAfterAWaitShowsWhatItShowed() async {
        let a = BrowserChromeSharedEdgeTests.tab("a.example")
        let stateA = BrowserChromeTabState()
        let pane = BrowserPaneChrome()
        let chrome = pane.bind(a, state: stateA)
        let window = BrowserChromeSharedEdgeTests.window(chrome)
        defer { window.close(); pane.drop(); a.close() }
        await BrowserChromeSharedEdgeTests.settle()
        chrome.addressBar.controller.send(.focusGained(.keyboard))
        chrome.addressBar.controller.send(.fieldChanged(OmnibarInput.Field(text: "kept", selection: NSRange(location: 4, length: 0)), .insert))

        chrome.awaitNewTab()
        pane.bind(a, state: stateA)  // the new tab went before its page came
        #expect(!chrome.isAwaitingTab)
        #expect(!a.contentView.isHidden, "A's page shows again")
        #expect(chrome.addressBar.displayedText == "kept", "A's omnibar text comes back: \(chrome.addressBar.displayedText)")
    }
}
