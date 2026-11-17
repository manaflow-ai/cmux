import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Lawrence 2026-11-16: "cmd option enter / browser focus mode sometimes doesn't work". A browser
/// tab a person opens starts on a stand-in (`pending_tab_…`) whose page and chrome move to the
/// daemon's tab on the reply (`TabContentCache.moveBrowser`); the page keeps its own id. Toggle
/// Browser Focus Mode named the tab by that page id, which the focus model does not know (its
/// topology has the daemon's id), so the reducer refused the toggle: every newly opened tab
/// ignored Opt-Cmd-Return until the app restarted (restored tabs have no stand-in, so they worked).
@MainActor @Suite(.serialized) struct BrowserFocusModeStandInTabTests {
    @Test func focusModeNamesTheDaemonTabAfterTheStandInMoved() throws {
        let cache = TabContentCache(daemon: DaemonService(), cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()),
                                    fileInput: NoFileInput(), afterFrame: { $0() })
        cache.browserTabs.cefUnavailable = { nil }
        cache.chromiumNow.runs = { true }
        cache.chromiumNow.make = { MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab($0) }
        let provisional = ProvisionalTab()
        let standIn = TabModel(TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.id), kind: .browser,
                                           url: BrowserNewTabPage.chromiumURL, browserRenderer: "frontend", browserEngine: "cef"))
        let daemonTab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 44), tabResourceID: ResourceID(rawValue: "tab_44"), kind: .browser,
                                             url: BrowserNewTabPage.chromiumURL, browserRenderer: "frontend", browserEngine: "cef"))
        defer { cache.release(daemonTab.id) }
        _ = cache.browser(for: standIn)
        let entry = try #require(cache.browser(for: standIn))
        #expect(cache.moveBrowser(standIn.id, to: daemonTab))
        #expect(entry.tab.id.rawValue != daemonTab.id, "the premise: the moved page keeps its stand-in id")
        #expect(entry.key == daemonTab.id, "the toggle names a tab the focus model does not show")
    }
}
