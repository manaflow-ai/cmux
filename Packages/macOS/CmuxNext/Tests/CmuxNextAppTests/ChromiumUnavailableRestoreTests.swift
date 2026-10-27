import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A copy of cmux whose Chromium could not start never restores a Chromium tab into WebKit, where it has none
/// of Chromium's cookies and a signed-in page came back as github.com/login?return_to=… (field log, 2026-10-26).
/// The tab shows "Chromium unavailable"; Reload tries again.
@MainActor @Suite(.serialized) struct ChromiumUnavailableRestoreTests {
    private func cache(_ reason: CEFUnavailableReason?) -> TabContentCache {
        let cache = TabContentCache(daemon: DaemonService(), cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()), fileInput: NoFileInput())
        cache.browserTabs.cefUnavailable = { reason }
        return cache
    }

    private func restoredChromiumTab(_ surface: UInt64) -> TabModel {
        TabModel(TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .browser, url: "https://github.com/settings/tokens",
                             browserRenderer: "frontend", browserEngine: "cef"))
    }

    @Test func onlyAStartFailureHoldsTheTab() {
        #expect(CEFUnavailableReason.startFailed("CefInitialize failed").keepsChromiumTabsOutOfWebKit)
        #expect(!CEFUnavailableReason.notBundled.keepsChromiumTabsOutOfWebKit, "a build without Chromium keeps its WebKit fallback")
        #expect(!CEFUnavailableReason.downloading(fraction: nil).keepsChromiumTabsOutOfWebKit)
        #expect(!CEFUnavailableReason.downloadFailed("offline").keepsChromiumTabsOutOfWebKit)
    }

    @Test func aBuildWithoutChromiumStillOpensTheTabInWebKit() throws {
        let cache = cache(.notBundled)
        let tab = restoredChromiumTab(63)
        defer { cache.release(tab.id) }
        let entry = try #require(cache.browser(for: tab))
        #expect(!(entry.tab is DeferredBrowserTab))
        #expect(entry.tab.engineKind == .webkit)
    }

    @Test func aRestoredChromiumTabWaitsInsteadOfLoadingInWebKit() throws {
        let cache = cache(.startFailed("CefInitialize failed"))
        let tab = restoredChromiumTab(61)
        defer { cache.release(tab.id) }
        let entry = try #require(cache.browser(for: tab))
        let page = try #require(entry.tab as? DeferredBrowserTab, "no WebKit page: nothing loads")
        #expect(page.engineKind == .cef)
        #expect(page.state.url?.absoluteString == "https://github.com/settings/tokens", "the address bar keeps the tab's page")
    }

    @Test func reloadTriesAgainAndWaitsAgainWhileChromiumStillCannotStart() throws {
        let cache = cache(.startFailed("CefInitialize failed"))
        let tab = restoredChromiumTab(62)
        defer { cache.release(tab.id) }
        cache.findTab = { $0 == tab.id ? tab : nil }
        var ready: [String] = []
        cache.onBrowserReady = { ready.append($0) }
        let first = try #require(cache.browser(for: tab))
        first.tab.reload()
        #expect(ready == [tab.id])
        let again = try #require(cache.existingBrowser(tab.id))
        #expect(again !== first, "the retry asked for the page again")
        #expect(again.tab is DeferredBrowserTab, "still no WebKit page")
    }

    /// An address typed into a "Chromium unavailable" tab is kept: the tab waits again on that address.
    @Test func aTypedAddressIsKeptWhileChromiumStillCannotStart() throws {
        let cache = cache(.startFailed("CefInitialize failed"))
        let tab = restoredChromiumTab(64)
        defer { cache.release(tab.id) }
        cache.findTab = { $0 == tab.id ? tab : nil }
        let first = try #require(cache.browser(for: tab))
        let typed = try #require(URL(string: "https://example.com/typed"))
        first.tab.load(typed)
        let again = try #require(cache.existingBrowser(tab.id)?.tab as? DeferredBrowserTab)
        #expect(again.state.url == typed)
    }

    /// A stand-in tab's "Chromium unavailable" page that moved to its daemon tab retries under the daemon tab's id.
    @Test func aMovedStandInRetriesUnderItsDaemonTab() throws {
        let cache = cache(.startFailed("CefInitialize failed"))
        let provisional = ProvisionalTab()
        let standIn = TabModel(TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.id), kind: .browser,
                                           url: "https://example.com/", browserRenderer: "frontend", browserEngine: "cef"))
        let daemonTab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 65), tabResourceID: ResourceID(rawValue: "tab_65"), kind: .browser,
                                             url: "https://example.com/", browserRenderer: "frontend", browserEngine: "cef"))
        defer { cache.release(daemonTab.id) }
        cache.findTab = { $0 == daemonTab.id ? daemonTab : nil }
        let first = try #require(cache.chromiumUnavailable(standIn, url: URL(string: "https://example.com/"), reason: .startFailed("x")) as BrowserEntry?)
        #expect(cache.moveBrowser(standIn.id, to: daemonTab))
        var ready: [String] = []
        cache.onBrowserReady = { ready.append($0) }
        first.tab.reload()
        #expect(ready == [daemonTab.id])
        #expect(cache.existingBrowser(daemonTab.id)?.tab is DeferredBrowserTab)
    }
}
