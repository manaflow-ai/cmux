import CmuxNextCompat
@testable import CmuxNextSidebar
import Foundation
import Testing

/// p07-memory-054: the sidebar's caches. The document store's projection memo is one lossless memory
/// consumer that its owner registers: a new limit frees nothing, a release at critical drops the memo
/// and keeps what the sidebar draws, and the next projection rebuilds it with a reducer call. The emoji
/// ink cache grew with every emoji and size it measured; it now stays within its limit.
@MainActor @Suite(.serialized) struct SidebarCacheMemoryTests {
    /// A registry that hands each new consumer `limit` at once, as the coordinator does.
    @MainActor private final class FakeRegistry: MemoryConsumerRegistry {
        var limit = MemoryLimit.default
        var entries: [MemoryConsumerEntry] = []

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            entries.append(entry)
            entry.liveConsumer?.updateMemoryLimit(limit)
        }
    }

    private typealias Fixture = SidebarDocReorderProjectionCostTests

    private static func slice(_ percent: Int) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: MemoryLimit(percent: percent)) { false }
    }

    @Test func criticalDropsTheProjectionMemoAndTheNextProjectionRebuildsIt() async throws {
        let store = try await Fixture.loaded()
        let registry = FakeRegistry()
        store.registerMemoryConsumer(with: registry)
        #expect(registry.entries.map(\.name) == [SidebarDocProjectionMemory.memoryConsumerName])
        let consumer = try #require(registry.entries.first?.liveConsumer)
        let live = Fixture.placed.map(Fixture.ref)
        store.show(live: live)
        let shown = try #require(store.shown, "the store shows no projection")
        #expect(consumer.memoryUsage?.entries == 1)
        #expect((consumer.memoryUsage?.footprintBytes ?? 0) > 0)

        #expect(consumer.releaseMemory(within: Self.slice(100)) == .done)
        #expect(store.projectionCache != nil, "a release at a full limit dropped the memo")
        consumer.updateMemoryLimit(.criticalThreshold)
        #expect(store.projectionCache != nil, "a new limit freed the memo")

        #expect(consumer.releaseMemory(within: Self.slice(0)) == .done)
        #expect(store.projectionCache == nil, "a release at critical kept the memo")
        #expect(consumer.memoryUsage == .empty)
        #expect(store.shown == shown, "the release changed what the sidebar draws")

        let before = Fixture.views
        #expect(store.projection(live: live) == shown)
        #expect(Fixture.views > before, "the projection after a release did not rebuild")
        #expect(consumer.memoryUsage?.entries == 1)
    }

    @Test func theProjectionMemoLeavesTheRegistryWithItsStore() {
        let registry = FakeRegistry()
        do {
            let store = SidebarDocStore(remote: nil, mirror: nil)
            store.registerMemoryConsumer(with: registry)
            #expect(registry.entries.first?.liveConsumer?.memoryUsage == .empty)
            store.registerMemoryConsumer(with: registry)
            #expect(registry.entries.filter(\.isLive).count == 1, "a second registration kept the first one live")
        }
        #expect(registry.entries.allSatisfy { !$0.isLive }, "a gone store's memo is still registered")
    }

    @Test func theEmojiInkCacheStaysWithinItsLimit() {
        let limit = SidebarEmojiGlyphView.inkCacheLimit
        for index in 0..<(limit + 40) {
            _ = SidebarEmojiGlyphView.ink("😀", size: 4 + CGFloat(index) / 16, pixelScale: 1)
        }
        #expect(SidebarEmojiGlyphView.inkCacheCount > 0, "no emoji ink was measured")
        #expect(SidebarEmojiGlyphView.inkCacheCount <= limit)
        // A measure after the cache emptied computes the same ink again.
        let again = SidebarEmojiGlyphView.ink("😀", size: 4, pixelScale: 1)
        #expect(again != nil)
    }
}
