import AppKit
@testable import CmuxNextApp
import Testing

/// Leo (T3 Code ref, 2026-10-07): a full-page destination turns the
/// sidebar's footer into Back, which returns the window to the workspace it
/// showed. Home is where you land, not a destination, so it keeps the footer.
@MainActor
struct SidebarFooterBackWiringTests {
    @Test func aDestinationShowsBackAndBackReturnsToTheWorkspace() async throws {
        let (services, window, state, _) = try await TopPageTests.window()
        let model = window.sidebar.model
        let workspace = try #require(state.workspaceID)
        #expect(!model.showsBack, "a workspace keeps the footer")
        _ = TopPages.show(TopPageTests.route, services: services, in: state)
        #expect(window.shownTopPage == TopPageTests.route)
        #expect(model.showsBack, "a destination shows Back")
        model.onBack?()
        #expect(window.shownTopPage == nil)
        #expect(state.page == nil)
        #expect(state.workspaceID == workspace, "Back returns to the workspace it showed")
        #expect(!model.showsBack)
        window.teardown()
        withExtendedLifetime(services) {}
    }

    @Test func homeKeepsTheFooter() async throws {
        let (services, window, state, _) = try await TopPageTests.window()
        _ = TopPages.show(.home, services: services, in: state)
        #expect(window.shownTopPage == .home)
        #expect(!window.sidebar.model.showsBack)
        window.teardown()
        withExtendedLifetime(services) {}
    }
}
