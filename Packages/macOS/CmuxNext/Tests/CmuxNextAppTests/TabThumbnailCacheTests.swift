import CmuxNextCompat
@testable import CmuxNextTabs
import CoreGraphics
import Testing

/// Hover card thumbnails in purgeable pages: volatile except while a card shows one, a
/// thumbnail the kernel purged is a miss that leaves the cache (the card pictures the tab again), and the
/// hover cards' consumer reports locked bytes apart from volatile ones. The copy is drawn off the main actor,
/// and with feature `purgeableImageCaches` off the cache keeps the image itself.
@MainActor @Suite struct TabThumbnailCacheTests {
    private static let side = 32
    private static let bytes = side * side * 4

    private static func image() throws -> CGImage {
        let context = try #require(CGContext.bitmapOwningPixels(width: side, height: side, space: CGColorSpaceCreateDeviceRGB(),
                                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    @Test func aPurgedThumbnailIsAMissAndLeavesTheCache() async throws {
        let fakes = FakePurgeableAllocations()
        var cache = TabThumbnailCache(allocator: fakes.allocator)
        let first = try await cache.picture(of: Self.image())
        cache.insert(first, for: TabID("a"))
        let second = try await cache.picture(of: Self.image())
        cache.insert(second, for: TabID("b"))
        #expect(cache.bytes == 2 * Self.bytes)
        #expect(fakes.pages[0].purge())
        #expect(cache.image(for: TabID("a")) == nil, "a purged thumbnail was returned")
        #expect(cache.count == 1 && cache.bytes == Self.bytes, "a purged thumbnail stayed in the cache")
        #expect(cache.image(for: TabID("b")) != nil)
    }

    @Test func theHoverCardsReportLockedAndVolatileBytesApart() async throws {
        let fakes = FakePurgeableAllocations()
        let controller = TabHoverCardController()
        controller.thumbnails = TabThumbnailCache(allocator: fakes.allocator)
        for tab in ["a", "b"] {
            let picture = try await controller.thumbnails.picture(of: Self.image())
            controller.thumbnails.insert(picture, for: TabID(tab))
        }
        #expect(controller.memoryUsage == MemoryUsage(footprintBytes: 0, volatileBytes: 2 * Self.bytes, entries: 2))
        do {
            // image(for:) is mutating (a purged entry leaves the cache), so it runs outside #require's closure; the
            // do block ends the shown image's life before the last check.
            let shown = controller.thumbnails.image(for: TabID("a"))
            try withExtendedLifetime(try #require(shown)) { _ in
                #expect(controller.memoryUsage == MemoryUsage(footprintBytes: Self.bytes, volatileBytes: Self.bytes, entries: 2),
                        "a shown thumbnail was not counted as locked")
                #expect(!fakes.pages[0].purge(), "a shown thumbnail could be purged")
            }
        }
        #expect(controller.memoryUsage == MemoryUsage(footprintBytes: 0, volatileBytes: 2 * Self.bytes, entries: 2))
    }

    /// The thumbnail's pixels are copied off the main actor, when its picture is made; the insert copies nothing.
    @Test func anInsertCopiesNoPixelsOnTheMainActor() async throws {
        let fakes = FakePurgeableAllocations()
        var cache = TabThumbnailCache(allocator: fakes.allocator)
        let picture = try await cache.picture(of: Self.image())
        #expect(fakes.pages.count == 1 && fakes.madeOnMain == 0, "the thumbnail's pixels were copied on the main thread")
        cache.insert(picture, for: TabID("a"))
        #expect(fakes.pages.count == 1, "the insert copied the pixels")
    }

    /// `purgeableImageCaches` off (the default allocator): the cache keeps the image itself, as before, with no
    /// copy and no color conversion, and its bytes are all footprint.
    @Test func residentThumbnailsAreTheInsertedImagesAndAllFootprint() async throws {
        var cache = TabThumbnailCache()
        let inserted = try Self.image()
        let picture = await cache.picture(of: inserted)
        cache.insert(picture, for: TabID("a"))
        #expect(cache.image(for: TabID("a")) === inserted, "the cache returned a copy, not the inserted image")
        #expect(cache.usage(entries: 1) == MemoryUsage(footprintBytes: Self.bytes, entries: 1))
    }
}
