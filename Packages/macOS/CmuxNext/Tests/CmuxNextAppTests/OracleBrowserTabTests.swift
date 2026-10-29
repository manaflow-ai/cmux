#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextBrowserTabs
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextOracle
import CmuxNextTabs
import Foundation
import Observation
import Testing

/// The oracle's `tabs` facet read through the engine-neutral `BrowserTab` protocol: `engine` comes
/// from `engineKind` and every other field from `BrowserTabState`; with no engine page (none yet, or a hibernated or
/// deferred stand-in) the tab is `unloaded`; titles go in only as hashes; the app composes each pane's tabs as its
/// strip lists them, and a page installed later wakes a `wait_for` read.
/// Whether WebKit and Chromium reach the same state for one navigation is not shown here (MockBrowserTab drives
/// both engine kinds alike): that is the fleet tabs-and-browser journey's.
/// Run: `swift test --filter OracleBrowserTabTests`.
@MainActor @Suite(.serialized) struct OracleBrowserTabTests {
    /// A page on `kind` that loaded two addresses, was titled, zoomed and muted.
    private func page(_ kind: BrowserEngineKind) throws -> MockBrowserTab {
        let page = MockBrowserEngine(kind: kind).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/a")))
        page.load(try #require(URL(string: "https://example.com/b")))
        page.simulate(.titleChanged("Example B"))
        page.setZoom(1.25)
        page.setAudioMuted(true)
        return page
    }

    @Test func engineComesFromTheEngineKindAndEveryOtherFieldFromTheTabState() throws {
        let record = OracleTabsFacet.Tab.Record(url: "https://stale.example/", title: "Stale", zoom: 2, engine: "webkit")
        let webkit = OracleTabsFacet.Tab.browser(id: "tab_1", pinned: true, page: try page(.webkit), record: record, hibernated: false)
        let cef = OracleTabsFacet.Tab.browser(id: "tab_1", pinned: true, page: try page(.cef), record: record, hibernated: false)
        #expect(webkit.engine == "webkit")
        #expect(cef.engine == "cef")

        #expect(cef.url == "https://example.com/b")
        #expect(cef.titleHash == OracleValue.sha256("Example B"))
        #expect(cef.loadState == .finished)
        #expect(cef.canGoBack)
        #expect(cef.zoom == 1.25)
        #expect(cef.muted)
        #expect(cef.pinned)
        #expect(!cef.crashed)
        #expect(!cef.hibernated)
    }

    @Test func aCrashedPageIsCrashed() throws {
        for kind in BrowserEngineKind.allCases {
            let page = try page(kind)
            page.simulate(.processExited(BrowserProcessExit(reason: .crashed)))
            let tab = OracleTabsFacet.Tab.browser(id: "tab_1", pinned: false, page: page, record: .init(), hibernated: false)
            #expect(tab.crashed, "\(kind)")
        }
    }

    /// The chromium-renderer-hang journey's error state: a hung page is unresponsive until it
    /// answers, and its renderer's end makes it crashed and no longer unresponsive.
    @Test func aHungPageIsUnresponsiveUntilItAnswersOrEnds() throws {
        for kind in BrowserEngineKind.allCases {
            let page = try page(kind)
            #expect(!OracleTabsFacet.Tab.browser(id: "tab_1", pinned: false, page: page, record: .init(), hibernated: false).unresponsive)
            page.simulate(.unresponsiveChanged(true))
            let hung = OracleTabsFacet.Tab.browser(id: "tab_1", pinned: false, page: page, record: .init(), hibernated: false)
            #expect(hung.unresponsive, "\(kind)")
            #expect(hung.value["unresponsive"] == true, "\(kind)")
            page.simulate(.processExited(BrowserProcessExit(reason: .crashed)))
            let ended = OracleTabsFacet.Tab.browser(id: "tab_1", pinned: false, page: page, record: .init(), hibernated: false)
            #expect(!ended.unresponsive, "\(kind)")
            #expect(ended.crashed, "\(kind)")
        }
    }

    @Test func aTabWithNoPageReadsItsRecord() {
        let record = OracleTabsFacet.Tab.Record(url: "https://example.com/", title: "Saved", zoom: 1.5, engine: "cef")
        let tab = OracleTabsFacet.Tab.browser(id: "tab_2", pinned: false, page: nil, record: record, hibernated: false)
        #expect(tab.engine == "cef")
        #expect(tab.url == "https://example.com/")
        #expect(tab.titleHash == OracleValue.sha256("Saved"))
        #expect(tab.zoom == 1.5)
        #expect(tab.loadState == .unloaded)
        #expect(!tab.hibernated)
    }

    /// What the app holds for a hibernated tab: a HibernatedBrowserTab made from the page's state (as
    /// `BrowserHibernation.release` makes it) and the dormant flag. Its saved values show; nothing live does.
    @Test func aHibernatedTabIsUnloadedWithItsSavedValues() throws {
        let live = try page(.cef)
        try #require(live.state.phase == .finished && live.state.canGoBack)
        let asleep = HibernatedBrowserTab(id: live.id, engine: .cef, profile: live.profileID, state: live.state,
                                          favicon: nil, restoreState: .chromium("saved"), snapshot: { nil })
        let tab = OracleTabsFacet.Tab.browser(id: "tab_3", pinned: false, page: asleep, record: .init(), hibernated: true)
        #expect(tab.loadState == .unloaded)
        #expect(!tab.canGoBack)
        #expect(!tab.canGoForward)
        #expect(!tab.audible)
        #expect(!tab.crashed)
        #expect(tab.hibernated)
        #expect(tab.engine == "cef")
        #expect(tab.url == "https://example.com/b")
        #expect(tab.titleHash == OracleValue.sha256("Example B"))
        #expect(tab.zoom == 1.25)
        #expect(tab.muted)
        // The same tab with its dormant flag not yet read still says hibernated: the stand-in is the page.
        #expect(OracleTabsFacet.Tab.browser(id: "tab_3", pinned: false, page: asleep, record: .init(), hibernated: false).hibernated)
    }

    /// A restored tab whose page is not started yet: the same `unloaded` as a tab with no page, so whether its pane
    /// was presented (and got the stand-in) does not change the tab.
    @Test func aDeferredTabIsUnloadedLikeATabWithNoPage() throws {
        let url = try #require(URL(string: "https://example.com/later"))
        let deferred = DeferredBrowserTab(id: BrowserTabID(rawValue: "tab_4"), engine: .webkit, url: url, title: "Later")
        let record = OracleTabsFacet.Tab.Record(url: url.absoluteString, title: "Later", zoom: 1, engine: "webkit")
        let standIn = OracleTabsFacet.Tab.browser(id: "tab_4", pinned: false, page: deferred, record: record, hibernated: false)
        let none = OracleTabsFacet.Tab.browser(id: "tab_4", pinned: false, page: nil, record: record, hibernated: false)
        #expect(standIn.loadState == .unloaded)
        #expect(standIn == none)
    }

    @Test func titlesAreHashesOnly() {
        // sha256("abc"), the FIPS 180-2 test vector.
        #expect(OracleValue.sha256("abc") == "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let page = OracleTabsFacet.Tab.page(id: "local-page:settings:1", page: "settings", title: "Settings")
        #expect(page.titleHash == OracleValue.sha256("Settings"))
        #expect(OracleTabsFacet.Tab.browser(id: "tab_4", pinned: false, page: nil, record: .init(), hibernated: false).titleHash == nil)
    }

    @Test func theAppListProvidesTabs() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.tabs))
        #expect(facets.duplicates.isEmpty)
        let snapshot = try #require(try facets.beginCapture([.tabs]).completed)
        guard case .array? = snapshot["tabs"]?["panes"] else {
            Issue.record("tabs has no panes list: \(String(describing: snapshot["tabs"]))")
            return
        }
    }
}

// MARK: - The app's composition (`AppServices.oracleTabPanes`)

extension OracleBrowserTabTests {
    /// One pane: a terminal, then a pinned daemon browser tab (hibernated, no page), a session-local browser tab
    /// in `state`, and a Settings page tab.
    private struct Seeded {
        let services: AppServices
        let model: PaneModel
        let state: WindowState
        let terminal: String
        let browser: String
        let local: String
        let page: String
    }

    private func seed() throws -> Seeded {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let terminal = TabSnapshot(surface: 1, title: "~")
        let browser = TabSnapshot(surface: 2, kind: .browser, title: "Daemon", url: "https://example.com/d",
                                  pinned: true, browserRenderer: "frontend", browserEngine: "cef")
        let pane = PaneSnapshot(id: 1, tabs: [terminal, browser])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])]))
        let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        try #require(model.tabs.count == 2)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let local = LocalBrowserTab.make(url: URL(string: "https://example.com/l"))
        state.localBrowserTabs[model.id].append(local)
        let page = services.pages.open(.settings, in: model.id, of: services.daemon.store)
        services.cache.dormantTabs.set(model.tabs[1].id, true)
        return Seeded(services: services, model: model, state: state, terminal: model.tabs[0].id, browser: model.tabs[1].id,
                      local: local.id, page: page)
    }

    /// No window mounts the pane: its tabs in strip order, the terminal left out, the window's remembered selection.
    @Test func anUnmountedPaneListsItsTabsInStripOrder() throws {
        let seeded = try seed()
        seeded.state.selection.select(seeded.terminal, in: seeded.model.id)
        let panes = seeded.services.oracleTabPanes(strip: { _ in nil }, windows: [seeded.state])
        try #require(panes.count == 1)
        let pane = panes[0]
        #expect(pane.id == seeded.model.id)
        #expect(pane.tabs.map(\.id) == [seeded.browser, seeded.local, seeded.page], "the order or the terminal is wrong")
        #expect(pane.tabs.map(\.kind) == [.browser, .browser, .page])
        #expect(pane.selected == seeded.terminal, "the selection a window remembers is a terminal's")

        let daemon = pane.tabs[0]
        #expect(daemon.pinned)
        #expect(daemon.hibernated)
        #expect(daemon.loadState == .unloaded)
        #expect(daemon.engine == "cef")
        #expect(daemon.url == "https://example.com/d")
        #expect(daemon.titleHash == OracleValue.sha256("Daemon"))
        let local = pane.tabs[1]
        #expect(!local.pinned)
        #expect(!local.hibernated)
        #expect(local.url == "https://example.com/l")
        #expect(pane.tabs[2].page == "settings")
        #expect(pane.tabs[2].engine == nil)

        // No window holds the pane's local tabs: only the daemon and page tabs.
        let bare = seeded.services.oracleTabPanes(strip: { _ in nil }, windows: [])
        #expect(bare.first?.tabs.map(\.id) == [seeded.browser, seeded.page])
        #expect(bare.first?.selected == nil)
    }

    /// A mounted strip: its own selection wins over a window's memory, and a tab the strip hides is not listed.
    @Test func aMountedPaneListsWhatItsStripShows() throws {
        let seeded = try seed()
        let strip = PaneController(pane: seeded.model, daemon: seeded.services.daemon, layoutPaneID: LayoutPaneID(seeded.model.id),
                                   services: seeded.services, state: seeded.state)
        defer { strip.teardown() }
        let other = WindowState(record: try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w2","workspace_key":"w1"}"#.utf8)))
        other.selection.select(seeded.terminal, in: seeded.model.id)
        strip.stripModel.selectedID = StripTabID(seeded.local)
        let mounted: (PaneModel) -> PaneController? = { $0 === seeded.model ? strip : nil }

        var pane = try #require(seeded.services.oracleTabPanes(strip: mounted, windows: [other]).first)
        #expect(pane.selected == seeded.local, "the mounted strip's selection did not win")
        #expect(pane.tabs.map(\.id) == [seeded.browser, seeded.local, seeded.page])

        // A tab on its way to a dock is out of the strip, so out of the facet.
        strip.pendingDock = [seeded.browser]
        pane = try #require(seeded.services.oracleTabPanes(strip: mounted, windows: [other]).first)
        #expect(pane.tabs.map(\.id) == [seeded.local, seeded.page])
    }

    /// `wait_for` reads a main-actor facet again only when Observation sees a change (OracleSettleControl.read).
    /// A page installed after the read (a CEF page made later, a local tab's first page) must be one: the
    /// cache's page table is not observable, so without `pageInstalls` the wait would run to its deadline.
    @Test func aPageInstalledAfterTheReadWakesTheWait() throws {
        let seeded = try seed()
        let woke = WakeFlag()
        let before = withObservationTracking {
            seeded.services.oracleTabPanes(strip: { _ in nil }, windows: [seeded.state])
        } onChange: {
            woke.fire()
        }
        #expect(before.first?.tabs[1].loadState == .unloaded)
        seeded.services.cache.install(try page(.webkit), for: seeded.local)
        defer { seeded.services.cache.release(seeded.local) }
        #expect(woke.fired, "installing the local tab's page did not wake the read")
        let after = seeded.services.oracleTabPanes(strip: { _ in nil }, windows: [seeded.state])
        #expect(after.first?.tabs[1].loadState == .finished)
    }

    nonisolated final class WakeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var fired: Bool { lock.withLock { value } }
        func fire() { lock.withLock { value = true } }
    }
}
#endif
