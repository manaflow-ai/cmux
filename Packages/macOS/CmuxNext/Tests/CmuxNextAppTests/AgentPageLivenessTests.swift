import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextPages
import CmuxNextTestSupport
import Foundation
import Testing

/// The detector for agent pages that outlive their tab (`AgentTabs+Liveness`). Leo's NIGHTLY, 2026-11-18: two
/// agent pages with no tab still reported visible and kept the shared renderer busy. The rule: every live page is a
/// tab's page or is held by an owner that bounds it, and a page none holds is closed once it is out of sight.
///
/// Each case counts the pages of its own fixture that break the rule (`AgentPageCensus.violations`) or still draw
/// with no tab, at the end of the path, and needs 0.
@MainActor @Suite(.serialized)
struct AgentPageLivenessTests {
    private struct Fixture {
        let services: AppServices
        let window: NSWindow
        let pane: PaneController
        let made: (AgentPaneNewTab) -> AgentPaneView?
        let teardown: () -> Void
    }

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "liveness-ws"), name: "liveness", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "liveness-ws"), index: 0)])
        return tree
    }

    /// A window with one pane, the New Tab pool aimed at it, and an inert page maker (loaded and painted, as
    /// `NewTabSpareStaysInWindowTests`): a WebKit page draws while it is in a window and not hidden.
    private static func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["liveness-ws"], frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        let folder = FileManager.default.temporaryDirectory.appending(path: "liveness-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let html = folder.appending(path: "index.html")
        try Data("<html><body>liveness fixture</body></html>".utf8).write(to: html)
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        content.contentView.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        let pane = try #require(content.panes.values.first)
        var pages: [AgentPaneView] = []
        let made: (AgentPaneNewTab) -> AgentPaneView? = { page in
            let model = AgentPaneModel(host: services.agentTabs.host, newTab: page)
            guard let view = AgentPaneView(model: model, source: .bundled(html)) else { return nil }
            model.hasHandshake = true
            model.markPainted()
            view.redraw.nextFrameOverride = { body in body() }
            services.agentTabs.livePages.made(view) // as `AgentTabStore.makeView` registers each page it makes
            pages.append(view)
            return view
        }
        let pool = services.newTabSpares
        pool.dropAll()
        pool.capacity = 2
        pool.makeSpare = made
        pool.start()
        pool.retarget(window)
        try #require(pool.target === window, "fixture: the pool has no target window")
        return Fixture(services: services, window: window, pane: pane, made: made) {
            pool.makeSpare = nil
            pool.dropAll()
            pages.forEach { $0.close() }
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The census of `pages` only: other suites' pages may live in the same process.
    private static func census(_ tabs: AgentTabStore, _ pages: [AgentPaneView]) -> AgentPageCensus {
        let mine = Set(pages.map(ObjectIdentifier.init))
        return AgentPageCensus(pages: tabs.livePages.roles(owner: tabs.pageOwner()).filter { mine.contains(ObjectIdentifier($0.view)) }
            .map { .init(role: $0.role, visible: $0.view.drawsForEngine, inWindow: $0.view.window != nil) })
    }

    private static func isLive(_ view: AgentPaneView) -> Bool { !view.model.pageClosed }

    private static func settles(within limit: Duration, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    /// A closed New Tab page waits in the pool's parking for its tab's release (`AgentPaneSpareReturns`). When the
    /// release never comes it drew there, off screen and with no tab, until the next keep or warm, which a pool
    /// with its spare made never runs: the page lived and drew until the app quit. It leaves the window at the
    /// wait's limit, and the census closes it.
    @Test(.timeLimit(.minutes(1)))
    func aClosedNewTabPageWhoseReleaseNeverComesStopsDrawingAndCloses() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.teardown() }
        let tabs = fixture.services.agentTabs
        let page = try #require(fixture.made(NewTabPage.sparePage(fixture.services)), "fixture: no page")
        fixture.pane.view.install(page)
        try #require(page.window === fixture.window, "fixture: the page is not in the window")
        try #require(fixture.services.newTabSpares.keepInWindow(page), "fixture: the pool did not keep the closed page (\(fixture.services.newTabSpares.lastRecycleRefusal ?? "no reason"))")
        #expect(Self.census(tabs, [page]).count(.returning) == 1, "the closed page waits in the pool's parking")

        let stopped = await Self.settles(within: AgentPaneSpareReturns.limit + .seconds(1)) { !page.drawsForEngine }
        #expect(stopped, "a closed New Tab page whose release never came still draws in the parking with no tab")
        let closed = await Self.settles(within: AgentTabStore.orphanSweepDelay + AgentPageRetirer.delay + .seconds(3)) { !Self.isLive(page) }
        #expect(closed, "the closed page no tab holds was never closed: \(Self.census(tabs, [page]).pages)")
    }

    /// A page no owner holds that is out of sight (parked off screen, as a page a lost release leaves) is closed by
    /// the sweep a tab's release runs; it never draws again.
    @Test(.timeLimit(.minutes(1)))
    func anOrphanOutOfSightIsClosed() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.teardown() }
        let tabs = fixture.services.agentTabs
        let page = try #require(fixture.made(NewTabPage.sparePage(fixture.services)), "fixture: no page")
        let parking = PageOffscreenParking()
        fixture.window.contentView?.addSubview(parking)
        parking.fit(to: NSSize(width: 400, height: 300))
        parking.addSubview(page)
        defer { parking.removeFromSuperview() }
        #expect(Self.census(tabs, [page]).violations == 1, "the census sees the orphan")
        #expect(page.drawsForEngine, "fixture: an orphan in the parking draws")

        #expect(tabs.sweepOrphans() >= 1)
        let census = Self.census(tabs, [page])
        #expect(census.violations == 0 && census.visibleTabless == 0, "after the sweep: \(census.pages)")
        let closed = await Self.settles(within: AgentPageRetirer.delay + .seconds(3)) { !Self.isLive(page) }
        #expect(closed, "the orphan was retired but never closed")
    }

    /// An orphan a pane still shows stays (closing it would blank the pane); the census counts it.
    @Test(.timeLimit(.minutes(1)))
    func anOrphanAPaneShowsStaysAndIsCounted() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.teardown() }
        let tabs = fixture.services.agentTabs
        let page = try #require(fixture.made(NewTabPage.sparePage(fixture.services)), "fixture: no page")
        fixture.pane.view.install(page)
        tabs.sweepOrphans()
        #expect(page.superview === fixture.pane.view.contentHost, "the sweep took a page a pane shows")
        #expect(Self.census(tabs, [page]).violations == 1)
    }

    /// A tab's release: its page leaves the window in the release's turn (it never draws again with no tab) and
    /// closes after its teardown delay.
    @Test(.timeLimit(.minutes(1)))
    func aReleasedTabsPageStopsDrawingAndCloses() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.teardown() }
        let tabs = fixture.services.agentTabs
        let page = try #require(fixture.made(NewTabPage.sparePage(fixture.services)), "fixture: no page")
        let key = "liveness-tab"
        tabs.views[tabs.tabKey(key)] = page
        fixture.pane.view.install(page)
        #expect(Self.census(tabs, [page]).count(.tab) == 1)

        tabs.release(key)
        let census = Self.census(tabs, [page])
        #expect(census.violations == 0 && census.visibleTabless == 0, "right after the release: \(census.pages)")
        let closed = await Self.settles(within: AgentPageRetirer.delay + .seconds(3)) { !Self.isLive(page) }
        #expect(closed, "the released tab's page was never closed")
    }
}
