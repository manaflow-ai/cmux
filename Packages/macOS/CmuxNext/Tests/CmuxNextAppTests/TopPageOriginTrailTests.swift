import AppKit
@testable import CmuxNextApp
import CmuxNextHistory
import Foundation
import Testing

/// Chief decision 2026-10-09 (after the sidebar Back was removed): a top
/// page opened as a window's first step records where the window was (the
/// restored Home page or the workspace) as a Go Back entry, so Go Back
/// (Ctrl-minus, the titlebar arrow) always leaves the page. The fresh-launch
/// case: the trail has nothing for the window yet.
@MainActor
struct TopPageOriginTrailTests {
    @Test func goBackFromAFirstPageReturnsToTheRestoredHome() async throws {
        let (services, window, state, _) = try await TopPageTests.window()
        if services.pages.provider(.appStore) == nil { services.pages.register(StubPage(.appStore)) }
        let trail = services.locationTrail
        trail.now = { Date(timeIntervalSince1970: 2_000_000_000) }
        // Launch restores Home with no trail step (a restore is not a show).
        state.page = .home
        #expect(window.showTopPage(.home))
        #expect(window.shownTopPage == .home)
        // The window's earlier settles belong to the test's setup, not this launch.
        trail.clear(since: nil)
        #expect(!trail.trail.entries.contains { $0.location.window == state.id }, "a fresh launch: no trail for the window")

        _ = TopPages.show(.page(.appStore), services: services, in: state)
        #expect(window.shownTopPage == .page(.appStore))
        #expect(services.registry.perform("focusHistoryBack"))
        #expect(window.shownTopPage == .home, "Go Back leaves the App Store for the Home page it covered")
        #expect(state.page == .home)
        window.teardown()
        withExtendedLifetime(services) {}
    }

    @Test func goBackFromAFirstPageReturnsToTheWorkspace() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try LocationTrailWiringTests.tree(tabs: [7]))
        let window = try #require(services.windows.openWindow(workspaces: [LocationTrailWiringTests.key]))
        services.windows.reconcileMembership()
        defer { window.window?.close() }
        if services.pages.provider(.appStore) == nil { services.pages.register(StubPage(.appStore)) }
        let trail = services.locationTrail
        trail.now = { Date(timeIntervalSince1970: 2_000_000_000) }
        // The launched window's focused tab (the real app focuses its pane at launch).
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        await LocationTrailWiringTests.settle { window.focus.state.topology.contains(pane: pane.id) }
        window.focus.send(.selectTab(pane: pane.id, tab: pane.tabs[0].id, workspace: LocationTrailWiringTests.key, source: .mouse))
        await LocationTrailWiringTests.settle { trail.trail.current != nil }
        let workspace = try #require(window.state.workspaceID)
        // A fresh launch: nothing in the trail yet, the page is the first step.
        trail.clear(since: nil)

        _ = TopPages.show(.page(.appStore), services: services, in: window.state)
        #expect(window.shownTopPage == .page(.appStore))
        #expect(trail.trail.entries.count == 2, "the workspace, then the App Store: \(trail.trail.entries.map(\.location.title))")
        #expect(services.registry.perform("focusHistoryBack"))
        await LocationTrailWiringTests.settle { window.shownTopPage == nil }
        #expect(window.shownTopPage == nil, "Go Back leaves the App Store for the workspace it covered")
        #expect(window.state.page == nil)
        #expect(window.state.workspaceID == workspace)
    }

    private final class StubPage: InternalPageProvider {
        let page: InternalPageID
        init(_ page: InternalPageID) { self.page = page }
        var title: String { page.rawValue }
        var symbol: String { "square" }
        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
    }
}
