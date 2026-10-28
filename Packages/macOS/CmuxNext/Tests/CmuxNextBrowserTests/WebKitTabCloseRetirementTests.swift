import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing
import WebKit

/// Nightly crash 2026-10-25: Cmd-W held over many tabs freed WKWebViews whose pages were still
/// scrolling, and macOS 26.6's WebKit left their scroll event dispatcher registered with the display
/// link (SIGSEGV in `DisplayLink::notifyObserversDisplayDidRefresh`, bugs.webkit.org 315775). A
/// closed tab's web view now leaves its window at once and stays alive, its page open, until
/// `WebViewRetirement` closes the page after the scrolling stopped.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WebKitTabCloseRetirementTests {
    @Test func aClosedTabsWebViewLeavesItsWindowButIsNotFreedWithTheTab() {
        weak var released: WKWebView?
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        autoreleasepool {
            let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
            let tab = engine.makeWebKitTab()
            window.contentView = tab.contentView
            released = tab.webView
            #expect(tab.webView.window === window)
            tab.close()
        }
        let webView = released
        #expect(webView != nil, "the closed tab's page must not end in the close's turn")
        #expect(webView?.window == nil)
        if let webView { #expect(WebViewRetirement.isPageClosed(webView) == false) }
    }
}
