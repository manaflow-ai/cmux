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
    @Test func aTypedAddressIsKeptWhileChromiumStillCannotStart() async throws {
        let cache = cache(.startFailed("CefInitialize failed"))
        let tab = restoredChromiumTab(64)
        defer { cache.release(tab.id) }
        cache.findTab = { $0 == tab.id ? tab : nil }
        let first = try #require(cache.browser(for: tab))
        var written: [String] = []
        cache.browserTabs.update = { _, _, update in
            if let url = update.url { written.append(url) }
            return true
        }
        let typed = try #require(URL(string: "https://example.com/typed"))
        first.tab.load(typed)
        let again = try #require(cache.existingBrowser(tab.id)?.tab as? DeferredBrowserTab)
        #expect(again.state.url == typed)
        // Quit's flush waits for the write, so a quit right away still reopens the typed address.
        await cache.browserTabs.flushRecords()
        #expect(written == [typed.absoluteString], "the restart the notice asks for opens the typed address")
    }

    /// Typing B and then the record's own address A back before B's write lands: the restart opens A, not B.
    @Test func typingTheRecordsAddressBackWinsOverAnEarlierTypedWrite() async throws {
        let cache = cache(.startFailed("CefInitialize failed"))
        let tab = restoredChromiumTab(67)
        defer { cache.release(tab.id) }
        cache.findTab = { $0 == tab.id ? tab : nil }
        var written: [String] = []
        cache.browserTabs.update = { _, _, update in
            for _ in 0..<5 { await Task.yield() }  // the daemon answers later
            if let url = update.url { written.append(url) }
            return true
        }
        let first = try #require(cache.browser(for: tab))
        let original = try #require(tab.url.flatMap(URL.init(string:)))
        let typed = try #require(URL(string: "https://example.com/typed"))
        first.tab.load(typed)
        let second = try #require(cache.existingBrowser(tab.id)?.tab as? DeferredBrowserTab)
        second.load(original)
        await cache.browserTabs.flushRecords()
        #expect(written == [typed.absoluteString, original.absoluteString], "the last typed address is the record's")
    }

    /// An address typed while quit waits for the records is waited for too.
    @Test func quitsFlushWaitsForAnAddressTypedDuringIt() async throws {
        let cache = cache(.startFailed("CefInitialize failed"))
        let tab = restoredChromiumTab(68)
        defer { cache.release(tab.id) }
        cache.findTab = { $0 == tab.id ? tab : nil }
        let typed = try #require(URL(string: "https://example.com/typed"))
        let late = try #require(URL(string: "https://example.com/late"))
        var written: [String] = []
        cache.browserTabs.update = { [weak cache] _, _, update in
            for _ in 0..<5 { await Task.yield() }
            if let url = update.url { written.append(url) }
            // The person types again while quit waits.
            if written.count == 1 { (cache?.existingBrowser(tab.id)?.tab as? DeferredBrowserTab)?.load(late) }
            return true
        }
        let first = try #require(cache.browser(for: tab))
        first.tab.load(typed)
        await cache.browserTabs.flushRecords()
        #expect(written == [typed.absoluteString, late.absoluteString], "the flush ends after the late write")
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

    /// A plain Reload never writes the address it showed over the record: another client moved the tab, and
    /// the retry follows the record.
    @Test func aPlainReloadFollowsAChangedRecordAndWritesNothing() async throws {
        let cache = cache(.startFailed("CefInitialize failed"))
        let tab = restoredChromiumTab(66)
        let moved = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 66), kind: .browser, url: "https://example.com/moved",
                                         browserRenderer: "frontend", browserEngine: "cef"))
        defer { cache.release(tab.id) }
        var current = tab
        cache.findTab = { $0 == tab.id ? current : nil }
        var written: [String] = []
        cache.browserTabs.update = { _, _, update in
            if let url = update.url { written.append(url) }
            return true
        }
        let first = try #require(cache.browser(for: tab))
        current = moved  // workspace.open_url moved the record
        first.tab.reload()
        for _ in 0..<10 { await Task.yield() }
        #expect(written.isEmpty)
        let again = try #require(cache.existingBrowser(tab.id)?.tab as? DeferredBrowserTab)
        #expect(again.state.url?.absoluteString == "https://example.com/moved")
    }

    /// An incognito tab's record holds a placeholder: Reload keeps the address the tab showed, a typed one stays
    /// in memory, and nothing is written.
    @Test func anIncognitoTabKeepsItsAddressAcrossRetries() async throws {
        let cache = cache(.startFailed("CefInitialize failed"))
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 67), kind: .browser, url: "about:blank",
                                       browserRenderer: "frontend", browserEngine: "cef"))
        defer { cache.release(tab.id) }
        cache.findTab = { $0 == tab.id ? tab : nil }
        cache.browserTabs.isIncognitoTab = { $0 == tab.id }
        var written: [String] = []
        cache.browserTabs.update = { _, _, update in
            if let url = update.url { written.append(url) }
            return true
        }
        let secret = try #require(URL(string: "https://private.example/"))
        let first = cache.chromiumUnavailable(tab, url: secret, reason: .startFailed("x"))
        first.tab.reload()
        let second = try #require(cache.existingBrowser(tab.id)?.tab as? DeferredBrowserTab)
        #expect(second.state.url == secret)
        let typed = try #require(URL(string: "https://private.example/typed"))
        second.load(typed)
        let third = try #require(cache.existingBrowser(tab.id)?.tab as? DeferredBrowserTab)
        #expect(third.state.url == typed)
        third.reload()
        #expect((cache.existingBrowser(tab.id)?.tab as? DeferredBrowserTab)?.state.url == typed)
        for _ in 0..<10 { await Task.yield() }
        #expect(written.isEmpty, "an incognito address never reaches the record")
    }
}
