import Foundation
import Testing
@testable import CmuxNextHome

/// Lawrence: "ensure i can resize left part". The Home sidebar's width stays
/// between the list's minimum and half the window, starts at the list's
/// preferred width, is kept per window, and a double-click resets it.
@Suite struct HomeSidebarWidthTests {
    static func store() -> HomeSidebarWidth {
        let name = "home-sidebar-width-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return HomeSidebarWidth(defaults: defaults)
    }

    @Test func theWidthStaysBetweenTheMinimumAndHalfTheWindow() {
        #expect(HomeSidebarWidth.clamp(40, window: 1200) == HomeSidebarWidth.minimum)
        #expect(HomeSidebarWidth.clamp(300, window: 1200) == 300)
        #expect(HomeSidebarWidth.clamp(900, window: 1200) == 600)
        #expect(HomeSidebarWidth.clamp(300, window: 380) == 190)
        #expect(HomeSidebarWidth.clamp(300, window: 120) == HomeSidebarWidth.minimum, "a narrow window keeps the minimum")
        #expect(HomeSidebarWidth.clamp(100, window: 1200, minimum: 220) == 220, "the list's own minimum")
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
}
