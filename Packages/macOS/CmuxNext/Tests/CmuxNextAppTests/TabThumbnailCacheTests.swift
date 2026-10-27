import CmuxNextCompat
@testable import CmuxNextTabs
import CoreGraphics
import Testing

/// Hover card thumbnails in purgeable pages (p07-memory-107): volatile except while a card shows one, a
/// thumbnail the kernel purged is a miss that leaves the cache (the card pictures the tab again), and the
/// hover cards' consumer reports locked bytes apart from volatile ones.
@MainActor @Suite struct TabThumbnailCacheTests {
    private static let side = 32
    private static let bytes = side * side * 4

    private static func image() throws -> CGImage {
        let context = try #require(CGContext.bitmapOwningPixels(width: side, height: side, space: CGColorSpaceCreateDeviceRGB(),
                                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    @Test func aPurgedThumbnailIsAMissAndLeavesTheCache() throws {
        let fakes = FakePurgeableAllocations()
        var cache = TabThumbnailCache(allocator: fakes.allocator)
        cache.insert(try Self.image(), for: TabID("a"))
        cache.insert(try Self.image(), for: TabID("b"))
        #expect(cache.bytes == 2 * Self.bytes)
        #expect(fakes.pages[0].purge())
        #expect(cache.image(for: TabID("a")) == nil, "a purged thumbnail was returned")
        #expect(cache.count == 1 && cache.bytes == Self.bytes, "a purged thumbnail stayed in the cache")
        #expect(cache.image(for: TabID("b")) != nil)
    }

    @Test func theHoverCardsReportLockedAndVolatileBytesApart() throws {
        let fakes = FakePurgeableAllocations()
        let controller = TabHoverCardController()
        controller.thumbnails = TabThumbnailCache(allocator: fakes.allocator)
        controller.thumbnails.insert(try Self.image(), for: TabID("a"))
        controller.thumbnails.insert(try Self.image(), for: TabID("b"))
        #expect(controller.memoryUsage == MemoryUsage(footprintBytes: 0, volatileBytes: 2 * Self.bytes, entries: 2))
        try withExtendedLifetime(try #require(controller.thumbnails.image(for: TabID("a")))) { _ in
            #expect(controller.memoryUsage == MemoryUsage(footprintBytes: Self.bytes, volatileBytes: Self.bytes, entries: 2),
                    "a shown thumbnail was not counted as locked")
            #expect(!fakes.pages[0].purge(), "a shown thumbnail could be purged")
        }
        #expect(controller.memoryUsage == MemoryUsage(footprintBytes: 0, volatileBytes: 2 * Self.bytes, entries: 2))
    }

    /// Resident pages (`purgeableImageCaches` off, the default) keep the report as before: all footprint.
    @Test func residentThumbnailsAreAllFootprint() throws {
        var cache = TabThumbnailCache()
        cache.insert(try Self.image(), for: TabID("a"))
        #expect(cache.usage(entries: 1) == MemoryUsage(footprintBytes: Self.bytes, entries: 1))
    }
}
