import AppKit
@testable import CmuxNextApp
import Foundation
import Testing

/// Lawrence (2026-10-09): "bottom left in sidebar should never have 'back'
/// thing." The sidebar shows no Back control in any mode: a workspace, Home,
/// the App Store, or any other full-page destination. Leaving a page is the
/// page's own job, or the titlebar's Go Back (focusHistoryBack), or a sidebar row.
@MainActor
struct SidebarFooterHasNoBackTests {
    /// A page whose view is empty: a destination the test can show when the
    /// fixture services have no real provider for its id.
    private final class StubPage: InternalPageProvider {
        let page: InternalPageID
        init(_ page: InternalPageID) { self.page = page }
        var title: String { page.rawValue }
        var symbol: String { "square" }
        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
    }

    /// Every top page the sidebar can open, plus the test fixture's page.
    private static let pages: [InternalPageID] = [
        .appStore, .settings, .history, .bookmarks, .inbox, .tasks, .passwords, .keybindings,
        .whatsNew, .changelog, .coderouter, .diff, TopPageTests.page,
    ]

    /// The visible controls in the sidebar whose title, label or symbol names Back.
    private static func backControls(in window: WindowController) -> [String] {
        let sidebar = window.sidebar.container
        sidebar.layoutSubtreeIfNeeded()
        var found: [String] = []
        func visit(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0 else { return }
            if let button = view as? NSButton {
                let words = [button.title, button.accessibilityLabel() ?? "", button.image?.accessibilityDescription ?? ""]
                    .map { $0.lowercased() }
                if words.contains(where: { $0 == "back" || $0 == "go back" || $0.hasPrefix("back ") }) {
                    found.append("\(type(of: button)) \(words)")
                }
            }
            view.subviews.forEach(visit)
        }
        visit(sidebar)
        return found
    }

    @Test func noModeShowsBackInTheSidebar() async throws {
        let (services, window, state, _) = try await TopPageTests.window()
        for id in Self.pages where services.pages.provider(id) == nil {
            services.pages.register(StubPage(id))
        }
        #expect(Self.backControls(in: window).isEmpty, "a workspace: \(Self.backControls(in: window))")
        let routes: [TopPageRoute] = [.home] + Self.pages.map(TopPageRoute.page)
        for route in routes {
            _ = TopPages.show(route, services: services, in: state)
            #expect(window.shownTopPage == route, "\(route.rawValue) opens")
            let found = Self.backControls(in: window)
            #expect(found.isEmpty, "\(route.rawValue) shows Back in the sidebar: \(found)")
        }
        window.teardown()
        withExtendedLifetime(services) {}
    }

    /// With no sidebar Back, Go Back (the titlebar arrow, the menu, the
    /// shortcut) still leaves the App Store for the workspace it covered.
    @Test func goBackLeavesTheAppStoreForTheWorkspace() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try LocationTrailWiringTests.tree(tabs: [7]))
        let controller = try #require(services.windows.openWindow(workspaces: [LocationTrailWiringTests.key]))
        services.windows.reconcileMembership()
        defer { controller.window?.close() }
        if services.pages.provider(.appStore) == nil { services.pages.register(StubPage(.appStore)) }
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let trail = services.locationTrail
        var clock = Date(timeIntervalSince1970: 1_900_000_000)
        trail.now = { clock }
        await LocationTrailWiringTests.settle { controller.focus.state.topology.contains(pane: pane.id) }
        controller.focus.send(.selectTab(pane: pane.id, tab: pane.tabs[0].id, workspace: LocationTrailWiringTests.key, source: .mouse))
        await LocationTrailWiringTests.settle { trail.trail.current != nil }
        let workspace = try #require(controller.state.workspaceID)
        clock += 5
        _ = TopPages.show(.page(.appStore), services: services, in: controller.state)
        #expect(controller.shownTopPage == .page(.appStore))
        #expect(Self.backControls(in: controller).isEmpty)
        clock += 5
        #expect(services.registry.perform("focusHistoryBack"))
        await LocationTrailWiringTests.settle { controller.shownTopPage == nil }
        #expect(controller.shownTopPage == nil)
        #expect(controller.state.page == nil)
        #expect(controller.state.workspaceID == workspace)
    }
}
