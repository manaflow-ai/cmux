import CmuxNextCompat
import CmuxNextFileGrid
import CoreGraphics
import Foundation
import Testing

/// The grid's thumbnail cache as a memory consumer: a new limit frees nothing, a
/// release frees down to it, the critical limit keeps only the working set, and a tile asked for
/// after a release renders again.
@Suite struct ThumbnailCacheMemoryTests {
    private static func fill(_ cache: ThumbnailCache, _ count: Int) async {
        for index in 0..<count { _ = await cache.thumbnail(for: ThumbnailCacheTests.item("\(index).png"), side: 100, scale: 2) }
    }

    private static func cached(_ cache: ThumbnailCache, _ name: String) async -> Bool {
        await cache.cachedThumbnail(for: ThumbnailCacheTests.item(name), side: 100, scale: 2) != nil
    }

    @Test func aNewLimitFreesNothingAndAReleaseKeepsTheNewest() async {
        let cache = ThumbnailCache(capacity: 10, workingSet: 2, generator: CountingGenerator())
        await Self.fill(cache, 10)
        let updated = await cache.updateMemoryLimit(MemoryLimit(percent: 50))
        #expect(updated?.entries == 10)
        #expect(await cache.count == 10)
        let released = await cache.releaseMemory(downTo: MemoryLimit(percent: 50))
        #expect(released?.entries == 5)
        #expect(await cache.count == 5)
        #expect(await Self.cached(cache, "9.png"))
        #expect(await Self.cached(cache, "0.png") == false)
    }

    @Test func theCriticalLimitKeepsTheWorkingSetAndATileAskedTwiceRendersOnce() async {
        let cache = ThumbnailCache(capacity: 10, workingSet: 2, generator: CountingGenerator())
        await Self.fill(cache, 4)
        let one = await cache.bytes / 4
        _ = await cache.duration(for: ThumbnailCacheTests.item("a.mov", kind: .video))
        // Critical: the two newest tiles stay; older tiles and the movie lengths go.
        let usage = await cache.releaseMemory(downTo: .criticalThreshold)
        #expect(usage == MemoryUsage(footprintBytes: 2 * one, entries: 2))
        #expect(await Self.cached(cache, "3.png"))
        #expect(await Self.cached(cache, "0.png") == false)
        // Still critical: a tile asked for twice renders once and is kept; the oldest kept one goes.
        _ = await cache.thumbnail(for: ThumbnailCacheTests.item("0.png"), side: 100, scale: 2)
        #expect(await cache.thumbnail(for: ThumbnailCacheTests.item("0.png"), side: 100, scale: 2) != nil)
        #expect(await cache.renderCount == 5)
        #expect(await cache.count == 2)
        #expect(await Self.cached(cache, "3.png"))
        #expect(await Self.cached(cache, "2.png") == false)
        // Back at the full limit, a released tile renders once more and is kept again.
        _ = await cache.updateMemoryLimit(.default)
        _ = await cache.thumbnail(for: ThumbnailCacheTests.item("1.png"), side: 100, scale: 2)
        _ = await cache.thumbnail(for: ThumbnailCacheTests.item("1.png"), side: 100, scale: 2)
        #expect(await cache.renderCount == 6)
        #expect(await cache.count == 3)
    }

    @Test func usageCountsPixelBytesFromItsCounters() async {
        let cache = ThumbnailCache(capacity: 10, workingSet: 2, generator: CountingGenerator())
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
