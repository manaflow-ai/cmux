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
        let cache = TabContentCache(daemon: DaemonService(), cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()), fileInput: NoFileInput())
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

    /// A new tab's stand-in (PaneBrowserTabOpener.openStandIn, PL-cef-tab) on any address, a link's page
    /// included, has its page and chrome right after the frame of the key that made it: a tab
    /// opened here has no saved history to read first. Not in the key's turn: building the page
    /// and its chrome took 64-380 ms (Chromium) and about 190 ms (WebKit) on the fleet (mac26,
    /// cef-tab-bench), so the key's frame shows the tab selected on its themed pane, and the
    /// page follows in the next pass, with no asynchronous task in between.
    @Test func aStandInOnAnyAddressHasItsChromeRightAfterTheKeysFrame() throws {
        var afterFrame: [@MainActor () -> Void] = []
        let cache = TabContentCache(daemon: DaemonService(), cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()), fileInput: NoFileInput(), afterFrame: { afterFrame.append($0) })
        cache.browserTabs.cefUnavailable = { nil }
        cache.chromiumNow.runs = { true }
        cache.chromiumNow.make = { MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab($0) }
        let provisional = ProvisionalTab()
        let tab = TabModel(TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.id), kind: .browser,
                                       url: "https://example.com/", browserRenderer: "frontend", browserEngine: "cef"))
        defer { cache.release(tab.id) }
        var ready: [String] = []
        cache.onBrowserReady = { ready.append($0) }
        var settled = 0
        cache.onPagesSettled = { settled += 1 }
        #expect(cache.browser(for: tab) == nil, "the key's turn makes no page or chrome")
        #expect(afterFrame.count == 1)
        #expect(settled == 0, "a page is pending: the warmup's spare window waits")
        afterFrame.forEach { $0() }
        #expect(ready == [tab.id], "the pane asks again once the key's frame committed")
        #expect(settled == 1, "no page pending any more: the warmup may make its spare window")
        let entry = try #require(cache.browser(for: tab), "the stand-in's page exists in that pass")
        #expect(entry.tab.state.url?.absoluteString == "https://example.com/")
    }

    /// The stand-in's page and chrome move to the daemon's tab on the reply: the same objects
    /// under the daemon tab's id, never closed or rebuilt (a rebuild cost a second chrome, about
    /// 65 ms, and a page view remount on the fleet).
    @Test func aStandInsPageAndChromeMoveToTheDaemonsTab() throws {
        // The key's frame committed: the work runs at once.
        let cache = TabContentCache(daemon: DaemonService(), cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()), fileInput: NoFileInput(), afterFrame: { $0() })
        cache.browserTabs.cefUnavailable = { nil }
        cache.chromiumNow.runs = { true }
        cache.chromiumNow.make = { MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab($0) }
        let provisional = ProvisionalTab()
        let standIn = TabModel(TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.id), kind: .browser,
                                           url: BrowserNewTabPage.chromiumURL, browserRenderer: "frontend", browserEngine: "cef"))
        let daemonTab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 43), tabResourceID: ResourceID(rawValue: "tab_43"), kind: .browser,
                                             url: BrowserNewTabPage.chromiumURL, browserRenderer: "frontend", browserEngine: "cef"))
        defer { cache.release(daemonTab.id) }
        _ = cache.browser(for: standIn)
        let entry = try #require(cache.browser(for: standIn))
        let page = try #require(entry.tab as? MockBrowserTab)
        #expect(cache.moveBrowser(standIn.id, to: daemonTab))
        #expect(cache.existingBrowser(standIn.id) == nil)
        #expect(cache.existingBrowser(daemonTab.id) === entry, "the same chrome")
        #expect(cache.browser(for: daemonTab) === entry)
        #expect(entry.chrome.addressBar.tabKey == daemonTab.id)
        #expect(!page.isClosed)
    }

    /// A reopened tab on the New Tab page whose page cannot be made now (Chromium still
    /// starting) takes the asynchronous path, which must still find the tab's closed history:
    /// the fast path may claim it only for the page it makes.
    @Test func aNewTabPageNotMadeNowLeavesItsClosedHistoryForTheLaterPage() throws {
        let cache = TabContentCache(daemon: DaemonService(), cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()), fileInput: NoFileInput())
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
