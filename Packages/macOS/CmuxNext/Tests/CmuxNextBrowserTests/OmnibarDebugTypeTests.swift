import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextBrowser

/// `debugTypeAndCommit` (the `debug.omnibar_type` socket verb): text typed
/// through the field editor and a Return key event commit the same way a
/// person's typing and Return key do, without the window being key. In a
/// Chromium tab `chrome://extensions` opens that page; in a WebKit tab the
/// same text is searched. The window is offscreen and never shown.
@MainActor
@Suite(.serialized) struct OmnibarDebugTypeTests {
    final class Harness {
        let window: NSWindow
        let chrome: BrowserChromeView
        let tab: MockBrowserTab
        var events: [OmnibarEvent] = []

        init(engine: BrowserEngineKind) {
            tab = MockBrowserEngine(kind: engine).makeMockTab(BrowserTabConfiguration())
            chrome = BrowserChromeView(tab: tab, suggestionEngine: OmniboxSuggestionEngine(providers: []))
            window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = chrome
            chrome.layoutSubtreeIfNeeded()
            tab.load(URL(string: "https://example.org/start")!)
            chrome.onOmnibarEvent = { [weak self] in self?.events.append($0) }
        }

        func settle() async {
            for _ in 0..<50 { await Task.yield() }
            chrome.layoutSubtreeIfNeeded()
        }
    }

    @Test func chromeURLTypedInAChromiumTabOpensThePage() async {
        let h = Harness(engine: .cef)
        await h.settle()
        #expect(!h.window.isKeyWindow)
        #expect(h.chrome.addressBar.debugTypeAndCommit("chrome://extensions"))
        await h.settle()
        #expect(h.events.last == .didEndEditing(.commit(URL(string: "chrome://extensions/")!)))
        #expect(h.tab.state.url?.absoluteString == "chrome://extensions/")
        #expect(!h.chrome.addressBar.isEditing)
    }

    @Test func chromeURLTypedInAWebKitTabIsSearched() async {
        let h = Harness(engine: .webkit)
        await h.settle()
        #expect(h.chrome.addressBar.debugTypeAndCommit("chrome://extensions"))
        await h.settle()
        guard case .didEndEditing(.commit(let url))? = h.events.last else {
            Issue.record("no commit: \(h.events)")
            return
        }
        #expect(url.scheme == "https")
        #expect(url.absoluteString.contains("chrome"))
    }

    @Test func typingWithoutCommitLeavesTheFieldEditing() async {
        let h = Harness(engine: .cef)
        await h.settle()
        #expect(h.chrome.addressBar.debugTypeAndCommit("chrome://version", commit: false))
        await h.settle()
        #expect(h.chrome.addressBar.isEditing)
        #expect(h.chrome.addressBar.debugSnapshot.fieldText == "chrome://version")
        #expect(!h.events.contains { if case .didEndEditing = $0 { true } else { false } })
    }
}
