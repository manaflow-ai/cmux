import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Leo 2026-11-03 (ask-08552f8ea0): "we should be able to optimistically just have a "thing" open". A browser tab
/// opened straight into a split (a link to the right, Split Browser, the chat header's Browser, Insert New) showed
/// its split at once, but its stand-in had no page: the new pane drew empty until the daemon replied, and the
/// daemon's tab then built the page from nothing. The split's stand-in is now app-rendered, as a new tab's is, and
/// the daemon's tab takes its page when it first asks for one: one page, started in the click's turn.
@MainActor @Suite(.serialized) struct SplitStandInPageTests {
    private static func cache(_ daemon: DaemonService) -> TabContentCache {
        let cache = TabContentCache(daemon: daemon, cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()),
                                    fileInput: NoFileInput(), afterFrame: { $0() })
        cache.browserTabs.cefUnavailable = { nil }
        cache.chromiumNow.runs = { true }
        cache.chromiumNow.make = { MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab($0) }
        return cache
    }

    @Test func aSplitsStandInWithAnEngineIsAppRendered() {
        let provisional = ProvisionalTab()
        #expect(TabModel(provisional.browser("https://example.com/", engine: "cef", profile: nil)).isFrontendOwned)
        #expect(!TabModel(ProvisionalTab().browser("https://example.com/")).isFrontendOwned, "no engine (another machine): no page until the reply")
    }

    /// The daemon's tab, the first time a pane asks for its page, takes its stand-in's: the same page and chrome,
    /// never closed or rebuilt, whichever comes first (the pane showing it, or the opener's hand-over after the reply).
    @Test func theDaemonsTabTakesItsStandInsPageWhenItFirstAsks() throws {
        let daemon = DaemonService(), store = daemon.store
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])]))
        let cache = Self.cache(daemon)
        let provisional = ProvisionalTab(), url = "https://example.com/"
        let snapshot = provisional.browser(url, engine: "cef", profile: nil)
        let transaction = ClientTransactionID.generate()
        store.intend(.splitPane(pane: PaneID(rawValue: 1), direction: .right, ratio: 0.5, provisional: ProvisionalPane(holding: snapshot)), transaction: transaction)
        let standIn = TabModel(snapshot)
        _ = cache.browser(for: standIn) // the click's frame: pending
        let entry = try #require(cache.browser(for: standIn), "the split's stand-in has its page right after the click's frame")
        let page = try #require(entry.tab as? MockBrowserTab)

        let daemonTab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 43), tabResourceID: ResourceID(rawValue: "tab_43"), kind: .browser,
                                             url: url, browserRenderer: "frontend", browserEngine: "cef"))
        defer { cache.release(daemonTab.id) }
        ProvisionalTab.created(transaction, surface: daemonTab.surface, in: store)
        #expect(store.creations.standIn(replacedBy: daemonTab.surface) == provisional.id)

        #expect(cache.browser(for: daemonTab) === entry, "the daemon's tab built a second page")
        #expect(cache.existingBrowser(provisional.id) == nil)
        #expect(entry.state.tabKey == daemonTab.id)
        #expect(!page.isClosed)
        #expect(!cache.moveBrowser(provisional.id, to: daemonTab), "the opener's later hand-over finds nothing left to move")
    }

    /// Any other tab makes its own page: the lookup names only a tab that replaced a stand-in.
    @Test func aTabThatReplacedNoStandInMakesItsOwnPage() throws {
        let daemon = DaemonService()
        let cache = Self.cache(daemon)
        #expect(daemon.store.creations.standIn(replacedBy: SurfaceID(rawValue: 44)) == nil)
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 44), tabResourceID: ResourceID(rawValue: "tab_44"), kind: .browser,
                                       url: BrowserNewTabPage.chromiumURL, browserRenderer: "frontend", browserEngine: "cef"))
        defer { cache.release(tab.id) }
        #expect(cache.browser(for: tab) != nil)
    }
}
