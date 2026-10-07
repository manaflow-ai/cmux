import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextBrowser

/// A browser pane keeps the width its layout gives it. Nothing in the
/// chrome (a long URL in the omnibar, the find bar, the prompt bar) may hold
/// the pane wider: in a 200 pt pane such a minimum pushed the chrome past
/// the pane's edge (or grew an unconstrained window).
@MainActor
@Suite(.serialized) struct NarrowPaneChromeTests {
    @Test(arguments: [CGFloat(200), 240, 320])
    func chromeKeepsThePaneWidth(width: CGFloat) async {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let chrome = BrowserChromeView(tab: tab)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = chrome
        tab.load(URL(string: "https://github.com/manaflow-ai/cmux/pull/15808/files#diff-0123456789abcdef")!)
        chrome.showFindBar()
        for _ in 0..<20 { await Task.yield() }
        chrome.layoutSubtreeIfNeeded()
        #expect(window.frame.width == width)
        #expect(chrome.bounds.width == width)
    }
}
