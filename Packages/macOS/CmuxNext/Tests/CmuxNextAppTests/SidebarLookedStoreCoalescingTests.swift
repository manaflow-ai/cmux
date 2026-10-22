@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-21 (workspace switch speed of light): a switch stamps the workspace it leaves, and the stamps'
/// encode and defaults write never run inside the switch. Many switches coalesce into one write, and `flush()` (or
/// the coalescing delay) writes the latest stamps.
@MainActor @Suite struct SidebarLookedStoreCoalescingTests {
    private static let key = "cmux.next.sidebar.lastLooked"

    @Test func aStampDoesNotWriteTheDefaultsInItsOwnTurn() throws {
        let suite = "SidebarLookedStoreCoalescingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SidebarLookedStore(defaults: defaults)
        for n in 0..<50 { store.stamp(WorkspaceID("ws-\(n)")) }
        #expect(defaults.data(forKey: Self.key) == nil, "a stamp wrote the defaults inside the switch")
        store.flush()
        let data = try #require(defaults.data(forKey: Self.key))
        let saved = try JSONDecoder().decode([WorkspaceID: Date].self, from: data)
        #expect(saved.count == 50)
    }

    @Test func theCoalescedWriteLands() async throws {
        let suite = "SidebarLookedStoreCoalescingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SidebarLookedStore(defaults: defaults)
        store.stamp(WorkspaceID("ws-a"))
        // Test wait for the store's own bounded coalescing delay (500 ms), with margin.
        for _ in 0..<40 where defaults.data(forKey: Self.key) == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(defaults.data(forKey: Self.key) != nil, "the coalesced write never landed")
    }
}
