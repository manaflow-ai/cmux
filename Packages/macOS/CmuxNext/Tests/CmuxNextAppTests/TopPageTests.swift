import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// TOP-SECTION-ITEMS-ARE-PAGES (Lawrence 2026-10-05: "home/app store/anything
/// in top section should be their own pages"): a top-section item opens its
/// own page in the window's content area, in place of the workspace (no tab
/// strip, panes or splits). The workspace stays mounted and comes back when
/// the user selects it; the page keeps its view (and so its state); the
/// window's record keeps the page across a relaunch.
@MainActor
struct TopPageTests {
    // MARK: Routes

    @Test func topItemsMapToTheirPages() {
        #expect(TopPageRoute(.app("cmux/home"), in: .top) == .home)
        #expect(TopPageRoute(.app("cmux/app-store"), in: .top) == .page(.appStore))
        #expect(TopPageRoute(.app("acme/mail"), in: .top) == .page(AppPanePage.pageID("acme/mail")))
        #expect(TopPageRoute(.builtIn(.settings), in: .top) == .page(.settings))
    }

    /// Only the top section opens pages: Settings at the bottom stays a tab;
    /// launchers and workspace refs open no page.
    @Test func otherItemsOpenNoPage() {
        #expect(TopPageRoute(.builtIn(.settings), in: .bottom) == nil)
        #expect(TopPageRoute(.app("cmux/app-store"), in: .middle) == nil)
        #expect(TopPageRoute(.builtIn(.newWorkspace), in: .top) == nil)
        #expect(TopPageRoute(.workspace("s:ws_1"), in: .top) == nil)
    }

    @Test func routesRoundTripThroughTheirPersistedForm() {
        for route in [TopPageRoute.home, .page(.appStore), .page(AppPanePage.pageID("acme/mail"))] {
            #expect(TopPageRoute(rawValue: route.rawValue) == route)
        }
        #expect(TopPageRoute(rawValue: "") == nil)
        #expect(TopPageRoute(rawValue: "page:") == nil)
    }

    // MARK: Window

    @Test func aPageReplacesTheWorkspaceAndTheWorkspaceComesBackUnchanged() async throws {
        let (services, window, state, provider) = try await Self.window()
        let workspaceID = try #require(state.workspaceID)
        let shownBefore = try #require(window.content)

        let key = TopPages.show(Self.route, services: services, in: state)
        #expect(key != nil, "the page opened")
        #expect(state.page == Self.route)
        #expect(window.shownTopPage == Self.route, "the page fills the content area")
        #expect(window.content == nil, "no workspace content is shown under the page")
        #expect(window.parked.contains { $0 === shownBefore }, "the workspace stays mounted, parked")
        #expect(state.workspaceID == workspaceID, "the window still names its workspace")
        let pageView = try #require(window.topPages.views[Self.route])

        services.windows.select(workspaceID, in: state)
        await BrowserTabTests.settle { window.content != nil }
        #expect(state.page == nil, "selecting a workspace leaves the page")
        #expect(window.content === shownBefore, "the same mounted workspace swaps back")
        #expect(window.shownTopPage == nil)

        TopPages.show(Self.route, services: services, in: state)
        #expect(window.topPages.views[Self.route] === pageView, "the page keeps its view (its state)")
        #expect(provider.made == 1, "one view per route per window")
        window.teardown()
        withExtendedLifetime((services, state)) {}
    }

    /// Automation never changes the view (OWNERSHIP-PRINCIPLES): no page opens.
    @Test func automationOpensNoPage() async throws {
        let (services, window, state, _) = try await Self.window()
        let shown = ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            TopPages.show(Self.route, services: services, in: state)
        }
        #expect(shown == nil)
        #expect(state.page == nil)
        #expect(window.content != nil)
        window.teardown()
        withExtendedLifetime(services) {}
    }

    /// Go to Home (`home.show`, Cmd-1's default item) shows the Home page.
    @Test func goToHomeShowsTheHomePage() async throws {
        let (services, window, state, _) = try await Self.window()
        _ = services.registry.perform("home.show", invocation: ActionInvocation(origin: .user))
        #expect(state.page == .home)
        #expect(window.shownTopPage == .home)
        window.teardown()
        withExtendedLifetime(services) {}
    }

    // MARK: Persistence

    /// The window's record (what the personal projection stores verbatim)
    /// carries the page, and a window made from the decoded record shows it.
    @Test func theRecordKeepsThePageAcrossARelaunch() throws {
        var registry = WindowRegistry()
        _ = registry.openWindow(id: "w1", workspaceIDs: ["ws"])
        let state = WindowState(id: "w1", workspaceID: "ws")
        state.page = .page(.appStore)
        let record = try #require(registry.record("w1", state: state, order: 0))
        let stored = try JSONEncoder().encode(record)
        let restored = WindowState(record: try JSONDecoder().decode(WindowRecord.self, from: stored))
        #expect(restored.page == .page(.appStore))
        #expect(restored.workspaceID == "ws")

        state.page = nil
        let plain = try #require(registry.record("w1", state: state, order: 0))
        #expect(WindowState(record: plain).page == nil)
    }

    // MARK: Sidebar

    @Test func theShownPagesItemIsActive() {
        let infos = SidebarBridge.itemInfo(for: .defaults, registered: { _ in true }, shownPage: .page(.appStore))
        #expect(infos[LayoutItemID("itm_app_store")]?.isActive == true)
        #expect(infos[LayoutItemID("itm_home")]?.isActive == false)
        let home = SidebarBridge.itemInfo(for: .defaults, registered: { _ in true }, shownPage: .home)
        #expect(home[LayoutItemID("itm_home")]?.isActive == true)
    }

    // MARK: Fixture

    static let page = InternalPageID(rawValue: "top-page-test")
    static let route = TopPageRoute.page(page)

    final class Provider: InternalPageProvider {
        var made = 0
        var page: InternalPageID { TopPageTests.page }
        var title: String { "Test" }
        var symbol: String { "square" }
        func makeView(for key: String, in window: WindowController?) -> NSView {
            made += 1
            return NSView()
        }
    }

    static func window() async throws -> (AppServices, WindowController, WindowState, Provider) {
        let services = ActionBindingCoverageTests.boundServices()
        let provider = Provider()
        services.pages.register(provider)
        services.daemon.store.apply(snapshot: try ProviderTabOpenTests.tree(surfaces: [5]))
        let workspace = try #require(services.daemon.store.workspaces.first)
        let state = WindowState(workspaceID: workspace.id)
        let window = WindowController(state: state, services: services, frame: nil)
        services.windows.didActivate(window)
        await BrowserTabTests.settle { window.content != nil }
        _ = try #require(window.content)
        return (services, window, state, provider)
    }
}
