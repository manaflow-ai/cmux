import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import Foundation
import Testing

/// After cmux quits unexpectedly twice in a row, restored browser tabs still load when they show
/// (user, 2026-10-27: "instead of 'not opened after cmux restart' we need to just load/reload it when
/// it is visible to user"). A tab's page is made only when the tab shows (`PaneController.content`),
/// so a restart never loads every page at once.
@MainActor @Suite(.serialized) struct CrashRestartLazyPagesTests {
    private func cache() -> TabContentCache {
        let cache = TabContentCache(daemon: DaemonService(), cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()), fileInput: NoFileInput())
        cache.browserTabs.cefUnavailable = { .notBundled }
        return cache
    }

    private func restoredTab(_ surface: UInt64) -> TabModel {
        TabModel(TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .browser, url: "https://example.com/docs",
                             browserRenderer: "frontend"))
    }

    @Test func aRestoredTabLoadsWhenShownAfterASafeRestart() throws {
        let cache = cache()
        let tab = restoredTab(71)
        cache.crashedPages = ["some-other-tab"]
        var started: [String] = []
        cache.onRestoredPageStart = { started.append($0) }
        defer { cache.release(tab.id) }
        let entry = try #require(cache.browser(for: tab))
        #expect(!(entry.tab is DeferredBrowserTab), "the shown tab waited for Reload instead of loading")
        #expect(entry.chrome.noticeText == nil, "the shown tab said it was not reopened")
        #expect(started == [tab.id], "the run marker did not learn the page started")
    }

    /// The page that was loading when the restart loop ended waits, with its own notice; Reload opens it.
    @Test func thePageThatEndedTheLoopWaitsWithItsOwnNotice() throws {
        let cache = cache()
        let tab = restoredTab(72)
        defer { cache.release(tab.id) }
        cache.crashedPages = [tab.id]
        cache.findTab = { $0 == tab.id ? tab : nil }
        let entry = try #require(cache.browser(for: tab))
        let page = try #require(entry.tab as? DeferredBrowserTab)
        #expect(page.state.url?.absoluteString == "https://example.com/docs")
        #expect(entry.chrome.noticeText == CrashStrings.crashedPageNotice)
        page.reload()
        let started = try #require(cache.existingBrowser(tab.id))
        #expect(!(started.tab is DeferredBrowserTab), "Reload did not open the held page")
    }
}
