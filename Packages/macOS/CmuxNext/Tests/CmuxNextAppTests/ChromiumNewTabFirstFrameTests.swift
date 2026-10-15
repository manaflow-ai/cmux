import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
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
        let make = ChromiumNewTabNow.make
        ChromiumNewTabNow.make = { _, configuration in  // Chromium runs
            MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab(configuration)
        }
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 41), kind: .browser, url: BrowserNewTabPage.chromiumURL,
                                       browserRenderer: "frontend", browserEngine: "cef"))
        defer {
            ChromiumNewTabNow.make = make
            cache.release(tab.id)
        }
        let entry = try #require(cache.browser(for: tab), "the page and its toolbar exist in the turn the pane shows the tab")
        #expect(entry.tab.id.rawValue == tab.id)
        #expect(entry.tab.state.url?.absoluteString == BrowserNewTabPage.chromiumURL)
    }
}
