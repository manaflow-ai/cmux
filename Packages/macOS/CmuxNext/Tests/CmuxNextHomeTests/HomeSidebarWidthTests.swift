import Foundation
import Testing
@testable import CmuxNextHome

/// Lawrence: "ensure i can resize left part". The Home sidebar's width stays
/// between its minimum and half the window, starts at Messages' 300 pt, is
/// kept per window, a double-click resets it, and the pinned grid shows as
/// many columns as fit, up to three.
@Suite struct HomeSidebarWidthTests {
    static func store() -> HomeSidebarWidth {
        let name = "home-sidebar-width-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return HomeSidebarWidth(defaults: defaults)
    }

    @Test func theWidthStaysBetweenTheMinimumAndHalfTheWindow() {
        #expect(HomeSidebarWidth.clamp(100, window: 1200) == HomeSidebarWidth.minimum)
        #expect(HomeSidebarWidth.clamp(300, window: 1200) == 300)
        #expect(HomeSidebarWidth.clamp(900, window: 1200) == 600)
        #expect(HomeSidebarWidth.clamp(300, window: 380) == HomeSidebarWidth.minimum, "a narrow window keeps the minimum")
    }

    @Test func theWidthIsKeptPerWindowAndResets() {
        let store = Self.store()
        #expect(store.width(window: "w1") == nil)
        store.save(340, window: "w1")
        store.save(260, window: "w2")
        #expect(store.width(window: "w1") == 340)
        #expect(store.width(window: "w2") == 260)
        store.reset(window: "w1")
        #expect(store.width(window: "w1") == nil, "a double-click returns to the standard width")
        #expect(store.width(window: "w2") == 260)
    }

    @Test func theGridShowsAsManyColumnsAsFitUpToThree() {
        #expect(HomeSidebarWidth.gridColumns(width: 300, tileWidth: 98) == 3)
        #expect(HomeSidebarWidth.gridColumns(width: 600, tileWidth: 98) == 3)
        #expect(HomeSidebarWidth.gridColumns(width: 220, tileWidth: 98) == 2)
        #expect(HomeSidebarWidth.gridColumns(width: 60, tileWidth: 98) == 1)
    }
}
