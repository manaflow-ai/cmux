import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// #32909: Shift-Cmd-L built the whole browser chrome in its key turn, 25-40 ms on an E core: the
/// find bar, the prompt bar, the load error page, the sad tab and the "Page unresponsive" card, and
/// every toolbar button, shown or not. Chrome makes the find bar and the infobars when they first
/// show. The first frame needs the toolbar and the address bar only; the rest is made on first use
/// and then works as before.
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserChromeFirstFrameTests {
    static func tab() -> MockBrowserTab {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        tab.showsExtensionToolbar = true
        return tab
    }

    static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    static func window(_ chrome: BrowserChromeView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        chrome.frame = window.contentLayoutRect
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        return window
    }

    /// Lets the observation loops (one main-actor task each) render.
    static func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// The views a new chrome holds that its first frame does not show.
    static func hiddenParts(of chrome: BrowserChromeView) -> [String] {
        let views = descendants(of: chrome)
        let pageBars = views.filter { $0 is FindBarView || $0 is PromptBarView || $0 is LoadErrorView || $0 is PageGoneView || $0 is PageUnresponsiveView }
        let hiddenButtons = views.compactMap { $0 as? ChromeIconButton }.filter { $0.isDescendant(of: chrome.toolbarButtons) && $0.isHidden }
        return pageBars.map { String(describing: type(of: $0)) } + hiddenButtons.map { "hidden \($0.accessibilityIdentifier())" }
    }

    @Test func aNewChromeBuildsOnlyWhatItsFirstFrameShows() {
        let tab = Self.tab()
        let chrome = BrowserChromeView(tab: tab)
        defer { BrowserPageRetirement(tab: tab, chrome: chrome).retire() }
        let parts = Self.hiddenParts(of: chrome)
        #expect(parts.isEmpty, "the first frame shows none of these, yet the key turn built them: \(parts)")
        #expect(chrome.toolbarButtons.button(.overflow)?.isHidden == false, "More is in the first frame")
    }

    @Test func theFindBarIsMadeWhenItFirstShowsAndWorks() async {
        let tab = Self.tab()
        let chrome = BrowserChromeView(tab: tab)
        let window = Self.window(chrome)
        defer {
            window.close()
            BrowserPageRetirement(tab: tab, chrome: chrome).retire()
        }
        chrome.perform(.findInPage)
        chrome.layoutSubtreeIfNeeded()
        let bars = Self.descendants(of: chrome).compactMap { $0 as? FindBarView }
        #expect(bars.count == 1)
        let bar = bars.first
        #expect(bar?.isHidden == false)
        let page = chrome.contentContainer.convert(chrome.contentContainer.bounds, to: nil)
        let pill = bar.map { $0.convert($0.bounds, to: nil) } ?? .zero
        #expect(pill.width > 0 && page.contains(pill), "the find pill sits on the page: \(pill) in \(page)")
        #expect(pill.maxX < page.maxX && pill.maxY < page.maxY, "at the page's top trailing corner, inset")
        chrome.hideFindBar()
        chrome.perform(.findInPage)
        #expect(Self.descendants(of: chrome).compactMap { $0 as? FindBarView }.count == 1, "a second show reuses it")
    }

    /// Review of #32967: the find pill made on its first show still gets its hole in a child-window page in
    /// the same layout pass. Its glass is two levels down, so the chrome's layout read a zero glass frame and
    /// the page window drew over the pill until something else updated the holes.
    @Test func theFirstFindPillGetsItsHoleInThePageInOneLayoutPass() throws {
        let tab = Self.tab()
        let chrome = BrowserChromeView(tab: tab)
        let window = Self.window(chrome)
        defer {
            window.close()
            BrowserPageRetirement(tab: tab, chrome: chrome).retire()
        }
        chrome.perform(.findInPage)
        chrome.layoutSubtreeIfNeeded()
        let hole = try #require(tab.roundedOcclusions.first, "the shown find pill left no hole in the page")
        #expect(hole.rect.width > 0 && hole.rect.height > 0, "the hole is the pill's glass, not an empty rect: \(hole.rect)")
        #expect(tab.contentView.bounds.contains(hole.rect), "inside the page: \(hole.rect)")
    }

    @Test func aLoadErrorShowsTheErrorPage() async throws {
        let tab = Self.tab()
        let chrome = BrowserChromeView(tab: tab)
        let window = Self.window(chrome)
        defer {
            window.close()
            BrowserPageRetirement(tab: tab, chrome: chrome).retire()
        }
        let failing = try #require(URL(string: "http://devbox:8080"))
        let id = tab.makeNavigationID()
        tab.simulate(.started(id, url: failing))
        tab.simulate(.failed(id, BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                                                  message: "A server with the specified hostname could not be found.", failingURL: failing)))
        await Self.settle()
        let error = Self.descendants(of: chrome).compactMap { $0 as? LoadErrorView }.first
        #expect(error?.isHidden == false, "the failed load shows cmux's error page")
    }

    @Test func aPermissionRequestShowsThePromptBar() async {
        let tab = Self.tab()
        let chrome = BrowserChromeView(tab: tab)
        let window = Self.window(chrome)
        defer {
            window.close()
            BrowserPageRetirement(tab: tab, chrome: chrome).retire()
        }
        tab.enqueuePrompt(.permission(.camera), origin: "https://example.com") { _ in }
        await Self.settle()
        let bar = Self.descendants(of: chrome).compactMap { $0 as? PromptBarView }.first
        #expect(bar?.isHidden == false, "the permission request shows in the prompt bar")
    }
}
