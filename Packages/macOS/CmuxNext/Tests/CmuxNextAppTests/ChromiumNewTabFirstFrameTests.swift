import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserHistory
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Perceived speed (cmux NEXT, Cmd-Shift-L): a new Chromium tab was made on a later main-actor
/// turn even when Chromium already ran, so the pane showed the selected tab with no content for
/// a frame and the toolbar arrived a frame later. With Chromium running, a tab on the New Tab
/// page has its page and chrome when the pane first asks for its content.
@MainActor @Suite(.serialized) struct ChromiumNewTabFirstFrameTests {
    @Test func aNewTabPageHasItsChromeWhenThePaneFirstShowsIt() throws {
        let cache = TabContentCache(daemon: DaemonService(), cef: CEFEngine(layout: nil))
        cache.browserTabs.cefUnavailable = { nil }
        cache.chromiumNow.runs = { true }  // Chromium runs
        cache.chromiumNow.make = { MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab($0) }
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 41), kind: .browser, url: BrowserNewTabPage.chromiumURL,
                                       browserRenderer: "frontend", browserEngine: "cef"))
        defer { cache.release(tab.id) }
        let entry = try #require(cache.browser(for: tab), "the page and its toolbar exist in the turn the pane shows the tab")
        #expect(entry.tab.id.rawValue == tab.id)
        #expect(entry.tab.state.url?.absoluteString == BrowserNewTabPage.chromiumURL)
    }

    /// A new tab's stand-in (BrowserTabStandIn, PL-cef-tab) on any address, a link's page
    /// included, has its page and chrome when the pane first shows it: a tab opened here has no
    /// saved history to read first. Only the New Tab page did, so a link's tab showed empty
    /// until an asynchronous page task ran.
    @Test func aStandInOnAnyAddressHasItsChromeWhenThePaneFirstShowsIt() throws {
        let cache = TabContentCache(daemon: DaemonService(), cef: CEFEngine(layout: nil))
        cache.browserTabs.cefUnavailable = { nil }
        cache.chromiumNow.runs = { true }
        cache.chromiumNow.make = { MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab($0) }
        let provisional = ProvisionalTab()
        let tab = TabModel(TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.id), kind: .browser,
                                       url: "https://example.com/", browserRenderer: "frontend", browserEngine: "cef"))
        defer { cache.release(tab.id) }
        let entry = try #require(cache.browser(for: tab), "the stand-in's page exists in the turn the pane shows it")
        #expect(entry.tab.state.url?.absoluteString == "https://example.com/")
    }

    /// A reopened tab on the New Tab page whose page cannot be made now (Chromium still
    /// starting) takes the asynchronous path, which must still find the tab's closed history:
    /// the fast path may claim it only for the page it makes.
    @Test func aNewTabPageNotMadeNowLeavesItsClosedHistoryForTheLaterPage() throws {
        let cache = TabContentCache(daemon: DaemonService(), cef: CEFEngine(layout: nil))
        cache.chromiumNow.runs = { false }  // Chromium still starting
        cache.chromiumNow.make = { _ in Issue.record("no page is made while Chromium starts"); return nil }
        let url = try #require(URL(string: BrowserNewTabPage.chromiumURL))
        let histories = cache.pageRequests.closedHistories
        histories.save(HibernatedBrowserTab(id: BrowserTabID(rawValue: "closed"), engine: .cef, profile: .default,
                                            state: BrowserTabState(url: url, title: "New Tab"), favicon: nil,
                                            restoreState: .chromium("back-forward"), snapshot: { nil }))
        histories.expect(CmuxNextDaemon.ClosedItem(id: "closed:1", kind: .tab, screens: [.init(tabs: [.init(kind: "browser", url: url.absoluteString)])]))
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 42), kind: .browser, url: BrowserNewTabPage.chromiumURL,
                                       browserRenderer: "frontend", browserEngine: "cef"))
        #expect(ChromiumNewTabNow(cache: cache).page(tab, url: url) == nil)
        let later = histories.restoring(BrowserTabConfiguration(id: BrowserTabID(rawValue: tab.id), profile: .default, initialURL: url),
                                        url: url, local: true, tab: tab.id)
        #expect(later.restoreState == .chromium("back-forward"), "the asynchronous path's page restores the closed tab's history")
    }
}
