import CmuxNextCompat
import CmuxNextPages
import Foundation
import Testing

/// ``PageResourceDataCache``, the PNGs a page's dynamic resource source served, as one lossless
/// memory consumer: it counts its bytes, holds 0 entries at the critical limit and
/// stores nothing then, and keeps every entry at any other limit.
@MainActor @Suite struct PageResourceDataCacheTests {
    /// Keeps each registered entry and hands it the default limit, as the coordinator does at normal.
    @MainActor final class RecordingRegistry: MemoryConsumerRegistry {
        private(set) var entries: [MemoryConsumerEntry] = []

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            entries.append(entry)
            entry.liveConsumer?.updateMemoryLimit(.default)
        }
    }

    @Test func itRegistersAndCountsItsBytes() throws {
        let registry = RecordingRegistry()
        let cache = PageResourceDataCache(name: "test-pngs", memory: registry)
        let entry = try #require(registry.entries.first)
        #expect(entry.name == "test-pngs")
        #expect(entry.traits == PageResourceDataCache.memoryTraits)
        #expect(entry.isLive)

        cache.store(Data(count: 10), for: "a")
        cache.store(Data(count: 30), for: "b")
        cache.store(Data(count: 20), for: "a")
        #expect(cache.memoryUsage == MemoryUsage(footprintBytes: 50, entries: 2))
    }

    @Test func theCriticalLimitHoldsNoEntryAndOtherLimitsKeepThemAll() {
        let cache = PageResourceDataCache(name: "test-pngs", memory: RecordingRegistry())
        for key in ["a", "b", "c"] { cache.store(Data(count: 8), for: key) }

        cache.updateMemoryLimit(MemoryLimit(percent: 25))
        #expect(cache.releaseMemory(within: MemoryReleaseSlice(limit: MemoryLimit(percent: 25)) { false }) == .done)
        #expect(cache.count == 3, "the keys are bounded: only the critical limit releases")

        cache.updateMemoryLimit(.criticalThreshold)
        #expect(cache.releaseMemory(within: MemoryReleaseSlice(limit: .criticalThreshold) { false }) == .done)
        #expect(cache.count == 0)
        #expect(cache.storedBytes == 0)
        cache.store(Data(count: 8), for: "a")
        #expect(cache.count == 0, "nothing is stored at the critical limit")

        cache.updateMemoryLimit(.default)
        cache.store(Data(count: 8), for: "a")
        #expect(cache["a"] == Data(count: 8))
    }

    @Test func anExpiredSliceAsksForMoreTurns() {
        let cache = PageResourceDataCache(name: "test-pngs", memory: nil)
        for key in ["a", "b", "c"] { cache.store(Data(count: 8), for: key) }
        cache.updateMemoryLimit(.criticalThreshold)
        let expired = MemoryReleaseSlice(limit: .criticalThreshold) { true }
        #expect(cache.releaseMemory(within: expired) == .more)
        #expect(cache.count == 2, "one entry per expired slice")
        #expect(cache.releaseMemory(within: expired) == .more)
        #expect(cache.releaseMemory(within: expired) == .done)
        #expect(cache.memoryUsage == .empty)
    }
}
