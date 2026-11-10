import CmuxHomeCore
import CmuxNextHome
import CmuxNextSettings
import Foundation
import Testing

/// Review round 11 of cmux#37736: the Messages page's composer reports my typing again, through
/// HomeStore's own throttled start and stop (F4: `HomeStore.composing`, as the native composer did).
/// (F1, the first send kept before it leaves the queue, is in HomeMessagesR6NewMessageTests.)
@MainActor @Suite(.serialized)
struct HomeMessagesR11Tests {
    @Test func thePagesComposingStartsAndStopsMyTyping() async throws {
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: try HomeMessagesR6NewMessageTests.directory())
        store.start()
        defer { store.stop() }
        await HomeMessagesR6NewMessageTests.until { store.isOnline && !store.rows.isEmpty && store.me != nil }
        let id = try #require(store.rows.first?.id)
        let me = try #require(store.me?.id)
        let kept = HomeMessagesKept(store: store, keepLocation: { false })

        _ = try await kept.call("composing", ["conversation": .string(id.rawValue), "typing": .bool(true)])
        await HomeMessagesR6NewMessageTests.until { store.typing[id]?.contains(me) == true }
        #expect(store.typing[id]?.contains(me) == true, "the owner heard my typing start")

        _ = try await kept.call("composing", ["conversation": .string(id.rawValue), "typing": .bool(false)])
        await HomeMessagesR6NewMessageTests.until { store.typing[id]?.contains(me) != true }
        #expect(store.typing[id]?.contains(me) != true, "and stop")
    }
}
