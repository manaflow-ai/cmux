import AppKit
@testable import CmuxNextApp
import CmuxNextHistory
import Foundation
import Testing

/// TOP-SECTION-ITEMS-ARE-PAGES Q2: a page the user shows is a Back/Forward
/// entry, and going to that entry shows the page again in its window.
@MainActor
struct TopPageTrailTests {
    @Test func showingAPageRecordsIt() async throws {
        let (services, window, state, _) = try await TopPageTests.window()
        _ = TopPages.show(.home, services: services, in: state)
        let current = try #require(services.locationTrail.trail.current?.location)
        #expect(current.page == TopPageRoute.home.rawValue)
        #expect(current.window == state.id)
        #expect(current.key.machine == HistoryLocation.pageMachine)
        window.teardown()
        withExtendedLifetime(services) {}
    }

    @Test func goingToAPageEntryShowsThePage() async throws {
        let (services, window, state, _) = try await TopPageTests.window()
        // Two seconds apart: a quicker pass is coalesced (only where you stop is recorded).
        var clock = Date(timeIntervalSince1970: 3_000_000)
        services.locationTrail.now = { clock }
        _ = TopPages.show(.home, services: services, in: state)
        clock.addTimeInterval(2)
        _ = TopPages.show(TopPageTests.route, services: services, in: state)
        let index = try #require(services.locationTrail.trail.entries.firstIndex { $0.location.page == TopPageRoute.home.rawValue })
        #expect(services.locationTrail.go(toIndex: index))
        #expect(state.page == .home)
        #expect(window.shownTopPage == .home)
        window.teardown()
        withExtendedLifetime(services) {}
    }

    @Test func aPageEntryIsAvailableWhileItsPageHasAProvider() async throws {
        let (services, window, state, _) = try await TopPageTests.window()
        #expect(services.locationTrail.isAvailable(.page(TopPageRoute.home.rawValue, window: state.id, title: "Home")))
        #expect(services.locationTrail.isAvailable(.page(TopPageTests.route.rawValue, window: state.id, title: "Test")))
        #expect(!services.locationTrail.isAvailable(.page("page:no-such-page", window: state.id, title: "?")))
        window.teardown()
        withExtendedLifetime(services) {}
    }
}
