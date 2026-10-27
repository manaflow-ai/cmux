import AppKit
@testable import CmuxNextBrowser
import Testing
import CmuxNextWakeups

/// Perceived speed (cmux NEXT, Cmd-Shift-L): a new browser tab's toolbar showed Stop and a load
/// progress line on its first frame, then flipped to Reload while the line swept and faded, so
/// the chrome popped over several frames for a page the user never asked to load. Like
/// Chromium (which hides the throbber on its New Tab page), loading the New Tab page is quiet:
/// the toolbar shows its settled Reload button and no progress line from the first frame. A
/// real page still shows Stop and the line while it loads.
@MainActor @Suite(.serialized) struct NewTabQuietLoadTests {
    static func chrome(loading address: String) -> BrowserChromeView {
        let engine = MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false)
        let page = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: address)))
        let chrome = BrowserChromeView(tab: page, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        chrome.layoutSubtreeIfNeeded()
        #expect(page.state.isLoading, "the page is still loading when the tab first shows")
        return chrome
    }

    /// The chrome renders a state change on its scheduler's next run loop turn (`ObservationLoop`, no link runs here).
    static func rendered() async {
        for _ in 0..<10 { await Task.yield() }
        spinRunLoop()
    }

    static func spinRunLoop() {
        for _ in 0..<4 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }
    }

    static func progressBarOpacity(in view: NSView) -> Float? {
        if let line = view as? ProgressLineView { return line.layer?.sublayers?.first?.opacity }
        return view.subviews.lazy.compactMap(progressBarOpacity(in:)).first
    }

    @Test(arguments: [BrowserNewTabPage.chromiumURL, BrowserNewTabPage.blankURL])
    func theNewTabPageLoadsWithTheSettledToolbar(_ address: String) {
        let chrome = Self.chrome(loading: address)
        #expect(chrome.reloadButton.accessibilityLabel() == Strings.reload, "Reload, not Stop, on the first frame")
        #expect(Self.progressBarOpacity(in: chrome) == 0, "no progress line sweeps under the toolbar")
    }

    @Test func aRealPageStillShowsItsLoad() {
        let chrome = Self.chrome(loading: "https://example.com/")
        #expect(chrome.reloadButton.accessibilityLabel() == Strings.stop)
        #expect(Self.progressBarOpacity(in: chrome) == 1)
    }

    /// Review of #21059: a load the New Tab page starts itself (a tile, a link, a redirect) starts
    /// with no address (CEF's loading state comes before the commit names one), so the tab still
    /// reads the New Tab page until that load commits. It is a real page loading: Stop and the
    /// line show from its start, not only after a slow site commits.
    @Test func aPageOpenedFromTheNewTabPageShowsItsLoadBeforeItCommits() async {
        let engine = MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false)
        let page = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: BrowserNewTabPage.chromiumURL)))
        let chrome = BrowserChromeView(tab: page, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        chrome.layoutSubtreeIfNeeded()
        let newTab = page.state.activeNavigation!
        page.simulate(.committed(newTab, url: URL(string: BrowserNewTabPage.chromiumURL)))
        page.simulate(.finished(newTab))
        await Self.rendered()
        #expect(chrome.reloadButton.accessibilityLabel() == Strings.reload)

        page.simulate(.started(page.makeNavigationID(), url: nil))
        #expect(page.state.isLoading)
        await Self.rendered()
        #expect(chrome.reloadButton.accessibilityLabel() == Strings.stop, "Stop from the load's start")
        #expect(Self.progressBarOpacity(in: chrome) == 1)
    }
}
