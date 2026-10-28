@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextInput
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// At launch a restored Chromium tab's page gets its origin from where it shows. One that
/// shows is made at once as `.restoreVisible` (its engine starts Chromium after the first frame); one that
/// does not show is the deferred page (no notice), started by the first of: its tab shows, or startup
/// completes. With feature `cefLaunchOrigin` off (no launch scheduler in the slot) nothing changes.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct RestoredPageOriginTests {
    @Test func aRestoredPageThatShowsIsMadeAtOnceAsRestoreVisible() async throws {
        let f = RestoredPageFixture()
        let tab = try f.restore(surface: 4_001)
        f.show(tab)
        #expect(f.cache.browser(for: tab) == nil, "a Chromium page is made asynchronously")
        await f.ready(tab)
        #expect(f.made.origins == [.restoreVisible])
        #expect(!(f.cache.existingBrowser(tab.id)?.tab is DeferredBrowserTab))
    }

    @Test func aHiddenRestoredPageWaitsAsTheDeferredPageUntilItShows() async throws {
        let f = RestoredPageFixture()
        let tab = try f.restore(surface: 4_002)
        let entry = try #require(f.cache.browser(for: tab))
        #expect(entry.tab is DeferredBrowserTab, "a hidden restored page made a page before startup completed")
        #expect(entry.chrome.noticeText == nil, "a launch deferral shows the crash notice")
        #expect(f.made.origins.isEmpty)

        f.show(tab)
        await f.ready(tab)
        #expect(f.made.origins == [.restoreVisible], "a hidden page that shows during launch starts as a visible one")
    }

    @Test func aHiddenRestoredPageStartsAfterStartupCompletes() async throws {
        let f = RestoredPageFixture()
        let tab = try f.restore(surface: 4_003)
        #expect(f.cache.browser(for: tab)?.tab is DeferredBrowserTab)
        f.launch.complete()
        #expect(f.made.origins.isEmpty, "the start waits for its afterStartup turn")
        f.launch.fire()
        await f.ready(tab)
        #expect(f.made.origins == [.user], "after completion no origin waits")
    }

    @Test func aPageThatShowedWhenItsStartWasDecidedKeepsThatOriginWhenItHidesBeforeItIsMade() async throws {
        let f = RestoredPageFixture()
        let tab = try f.restore(surface: 4_005)
        f.show(tab)
        #expect(f.cache.browser(for: tab) == nil, "a Chromium page is made asynchronously")
        f.hide(tab)
        await f.ready(tab)
        #expect(f.made.origins == [.restoreVisible], "a page whose start was not deferred waited for startup complete")
    }

    @Test func aCommandOnAHiddenRestoredPageStartsItAtOnceAsAutomation() async throws {
        let f = RestoredPageFixture()
        let tab = try f.restore(surface: 4_006)
        let deferred = try #require(f.cache.browser(for: tab)?.tab as? DeferredBrowserTab)
        let live = try #require(await AppBrowserPage.awakePage(tab.id, page: deferred, cache: f.cache, within: .seconds(30)),
                                "a command on a launch-deferred page got no live page")
        #expect(!(live is DeferredBrowserTab))
        #expect(f.made.origins == [.automation], "a command's page waited for the launch order")
    }

    @Test func aCommandLeavesACrashDeferredPageForThePerson() async throws {
        let f = RestoredPageFixture()
        f.cache.defersRestoredPages = true
        let tab = try f.restore(surface: 4_007)
        let deferred = try #require(f.cache.browser(for: tab)?.tab as? DeferredBrowserTab)
        let page = await AppBrowserPage.awakePage(tab.id, page: deferred, cache: f.cache, within: .seconds(1))
        #expect(page === deferred)
        #expect(f.made.origins.isEmpty)
    }

    @Test func withTheFeatureOffAHiddenRestoredPageIsMadeAtOnce() async throws {
        let f = RestoredPageFixture(featureOn: false)
        let tab = try f.restore(surface: 4_004)
        #expect(f.cache.browser(for: tab) == nil)
        await f.ready(tab)
        #expect(f.made.origins == [.user])
    }
}

@MainActor
private final class RestoredPageFixture {
    let launch = StartupTestScheduler()
    let daemon = DaemonService()
    let cache: TabContentCache
    let made = MadeOrigins()
    private let pane = VisibilityNode(root: "pane", own: .visible)
    /// The selected tabs' nodes, held as `PaneController.selectedTabNode` holds them (the cache holds them weakly).
    private var shown: [String: VisibilityNode] = [:]
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var arrived: Set<String> = []

    init(featureOn: Bool = true) {
        let engine = CEFEngine(source: CEFRuntimeSource(layout: nil), stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(),
                               input: InputEventTap(), launch: featureOn ? launch.startup : nil)
        cache = TabContentCache(daemon: daemon, chromium: ChromiumEngineSlot(engine), fileInput: NoFileInput(), mainWork: linklessMainWork())
        cache.browserTabs.cefUnavailable = { nil }
        cache.chromiumNow.runs = { false }
        cache.makeCEFTab = { [made] configuration in
            made.origins.append(configuration.origin)
            return MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab(configuration)
        }
        cache.onBrowserReady = { [weak self] key in self?.arrive(key) }
    }

    /// A Chromium tab in the daemon's launch snapshot: a restored tab.
    func restore(surface: UInt64) throws -> TabModel {
        let tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .browser, url: "https://example.com/",
                              browserRenderer: "frontend", browserEngine: "cef")
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        daemon.store.applyProvisional(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let restored = try #require(daemon.store.tab(surface: SurfaceID(rawValue: surface)))
        #expect(daemon.store.restoredTabIDs.contains(restored.id))
        return restored
    }

    /// Selects `tab` in a visible pane (`PaneController.selectTabNode`).
    func show(_ tab: TabModel) {
        let node = cache.node(for: tab.id)
        try? node.attach(to: pane)
        node.set(.visible)
        shown[tab.id] = node
    }

    /// Hides `tab`'s shown node (its pane selected another tab, `PaneController.selectTabNode`).
    func hide(_ tab: TabModel) {
        shown[tab.id]?.set(.hidden)
    }

    /// Returns once `tab`'s Chromium page was installed (`onBrowserReady`).
    func ready(_ tab: TabModel) async {
        if arrived.remove(tab.id) != nil { return }
        await withCheckedContinuation { waiting[tab.id] = $0 }
    }

    /// A re-show with the page made (not the deferred page's start, which re-shows before its page exists).
    private func arrive(_ key: String) {
        guard let page = cache.existingBrowser(key)?.tab, !(page is DeferredBrowserTab) else { return }
        if let waiter = waiting.removeValue(forKey: key) { waiter.resume() } else { arrived.insert(key) }
    }
}

@MainActor
private final class MadeOrigins {
    var origins: [BrowserTabOrigin] = []
}
