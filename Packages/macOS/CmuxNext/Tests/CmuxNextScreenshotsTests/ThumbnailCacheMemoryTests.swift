import CmuxNextCompat
import CmuxNextFileGrid
import CoreGraphics
import Foundation
import Testing

/// The grid's thumbnail cache as a memory consumer (p07-memory-059): a new limit frees nothing, a
/// release frees down to it, the critical limit keeps nothing, and a tile asked for after a release
/// renders again.
@Suite struct ThumbnailCacheMemoryTests {
    private static func fill(_ cache: ThumbnailCache, _ count: Int) async {
        for index in 0..<count { _ = await cache.thumbnail(for: ThumbnailCacheTests.item("\(index).png"), side: 100, scale: 2) }
    }

    @Test func aNewLimitFreesNothingAndAReleaseKeepsTheNewest() async {
        let cache = ThumbnailCache(capacity: 10, generator: CountingGenerator())
        await Self.fill(cache, 10)
        let updated = await cache.updateMemoryLimit(MemoryLimit(percent: 50))
        #expect(updated?.entries == 10)
        #expect(await cache.count == 10)
        let released = await cache.releaseMemory(downTo: MemoryLimit(percent: 50))
        #expect(released?.entries == 5)
        #expect(await cache.count == 5)
        #expect(await cache.cachedThumbnail(for: ThumbnailCacheTests.item("9.png"), side: 100, scale: 2) != nil)
        #expect(await cache.cachedThumbnail(for: ThumbnailCacheTests.item("0.png"), side: 100, scale: 2) == nil)
    }

    @Test func theCriticalLimitHoldsNothingAndAHitAfterReleaseRendersAgain() async {
        let cache = ThumbnailCache(capacity: 10, generator: CountingGenerator())
        await Self.fill(cache, 4)
        _ = await cache.duration(for: ThumbnailCacheTests.item("a.mov", kind: .video))
        let usage = await cache.releaseMemory(downTo: .criticalThreshold)
        #expect(usage == MemoryUsage(footprintBytes: 0, entries: 0))
        #expect(await cache.bytes == 0)
        // Limit 0: a tile still gets its picture, and the cache keeps none.
        #expect(await cache.thumbnail(for: ThumbnailCacheTests.item("0.png"), side: 100, scale: 2) != nil)
        #expect(await cache.count == 0)
        #expect(await cache.renderCount == 5)
        // Back at the full limit, the released tile renders once more and is kept again.
        _ = await cache.updateMemoryLimit(.default)
        _ = await cache.thumbnail(for: ThumbnailCacheTests.item("0.png"), side: 100, scale: 2)
        _ = await cache.thumbnail(for: ThumbnailCacheTests.item("0.png"), side: 100, scale: 2)
        #expect(await cache.renderCount == 6)
        #expect(await cache.count == 1)
    }

    @Test func usageCountsPixelBytesFromItsCounters() async {
        let cache = ThumbnailCache(capacity: 10, generator: CountingGenerator())
        await Self.fill(cache, 1)
        let one = await cache.bytes
        #expect(one > 0)
        await Self.fill(cache, 3)
        #expect(await cache.bytes == 3 * one)
        let usage = await cache.updateMemoryLimit(.default)
        #expect(usage == MemoryUsage(footprintBytes: 3 * one, entries: 3))
        // 20 % of 10 keeps 2: the counter follows each removal.
        _ = await cache.releaseMemory(downTo: MemoryLimit(percent: 20))
        #expect(await cache.bytes == 2 * one)
    }
}
