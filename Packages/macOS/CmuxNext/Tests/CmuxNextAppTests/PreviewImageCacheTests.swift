import CmuxNextBridge
import CmuxNextCompat
import CmuxNextMemory
import CoreGraphics
import Testing

/// Tab previews, page thumbnails and discarded internal pages' pictures are sized from the image cache
/// budget and follow the memory coordinator: a limit lowers the cap and frees nothing, the
/// release slice drops the oldest images down to it, and the critical limit empties the cache. Terminal
/// previews give memory back at warning; caches holding the only copy of a picture wait for critical.
@MainActor @Suite
struct PreviewImageCacheTests {
    /// Keeps the coordinator's release slices until the test runs them, as the next frames would.
    final class HeldSlices: MemoryReleaseSlicer {
        private var slices: [@MainActor () -> Void] = []
        func scheduleSlice(_ slice: @escaping @MainActor () -> Void) { slices.append(slice) }
        func runAll() {
            while !slices.isEmpty { slices.removeFirst()() }
        }
    }

    /// A `side` x `side` RGBA image: `side * side * 4` bytes in the cache.
    private func image(side: Int = 64) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    /// A `side` x `side` image kept as itself (feature `purgeableImageCaches` off, the default).
    private func picture(side: Int = 64) throws -> PurgeablePicture {
        PurgeablePicture(resident: try image(side: side))
    }

    private static let imageBytes = 64 * 64 * 4

    private func filled(_ count: Int, contents: PreviewImageCache.Contents = .rebuildable) throws -> PreviewImageCache {
        let cache = PreviewImageCache(fullCapacityBytes: count * Self.imageBytes, contents: contents)
        for index in 0..<count { cache.insert(try picture(), for: "k\(index)") }
        return cache
    }

    private func release(_ cache: PreviewImageCache, to limit: MemoryLimit) -> MemoryReleaseProgress {
        cache.releaseMemory(within: MemoryReleaseSlice(limit: limit) { false })
    }

    @Test func aHalfLimitHalvesTheCapacityAndFreesNothingUntilTheRelease() throws {
        let cache = try filled(8)
        #expect(cache.count == 8 && cache.capacityBytes == 8 * Self.imageBytes)
        cache.updateMemoryLimit(MemoryLimit(percent: 50))
        #expect(cache.capacityBytes == 4 * Self.imageBytes, "a 50 % limit did not halve the capacity")
        #expect(cache.count == 8, "the limit freed images before the release slice")
        #expect(release(cache, to: MemoryLimit(percent: 50)) == .done)
        #expect(cache.count == 4 && cache.totalBytes == 4 * Self.imageBytes)
        #expect(cache.image(for: "k0") == nil && cache.image(for: "k7") != nil, "the release kept old images over new ones")
        cache.insert(try picture(), for: "new")
        #expect(cache.count == 4, "an insert under the half limit grew past the halved capacity")
    }

    @Test func theCriticalLimitEmptiesTheCacheAndKeepsNothingNew() throws {
        let cache = try filled(5)
        cache.updateMemoryLimit(.criticalThreshold)
        #expect(release(cache, to: .criticalThreshold) == .done)
        #expect(cache.count == 0 && cache.totalBytes == 0, "the critical limit left \(cache.count) previews")
        cache.insert(try picture(), for: "late")
        #expect(cache.count == 0, "a preview was kept at the critical limit")
        cache.updateMemoryLimit(.default)
        cache.insert(try picture(), for: "back")
        #expect(cache.count == 1, "the cache kept nothing after the limit came back")
    }

    @Test func anExpiredSliceAsksForMoreTurns() throws {
        let cache = try filled(4)
        let checks = ExpiryChecks()
        let slice = MemoryReleaseSlice(limit: .criticalThreshold) { checks.next() > 1 }
        #expect(cache.releaseMemory(within: slice) == .more)
        #expect(cache.count == 3, "a slice dropped more than its time allowed")
    }

    /// A refused picture drops the key's older one: before, a refused refresh left the stale picture,
    /// which the internal page's next hide took for current (its version was recorded).
    @Test func aRefusedInsertDropsTheKeysOlderImage() throws {
        let cache = try filled(4)
        cache.updateMemoryLimit(MemoryLimit(percent: 50))
        #expect(!cache.insert(try picture(side: 128), for: "k3"), "an image over the lowered cap was kept")
        #expect(cache.image(for: "k3") == nil, "a refused picture left the key's stale one")
        #expect(cache.insert(try picture(), for: "k3"))
    }

    /// Under a lowered cap an insert evicts only what the new image needs: the drop down to the cap is the
    /// coordinator's sliced release, never one insert's turn.
    @Test func anInsertUnderALoweredLimitEvictsOnlyWhatTheNewImageNeeds() throws {
        let cache = try filled(8)
        cache.updateMemoryLimit(MemoryLimit(percent: 25))
        cache.insert(try picture(), for: "new")
        #expect(cache.count == 8 && cache.totalBytes == 8 * Self.imageBytes,
                "one insert dropped \(9 - cache.count) images, more than the one it needed")
        #expect(cache.image(for: "k0") == nil && cache.image(for: "new") != nil)
        #expect(release(cache, to: MemoryLimit(percent: 25)) == .done)
        #expect(cache.count == 2)
    }

    @Test func registersAsALosslessCheapManagedConsumerAndReportsItsBytes() throws {
        let traits = PreviewImageCache.rebuildableTraits
        #expect(traits.isManaged && traits.retention == .lossless && traits.dataAccess == .none && traits.recreateCost == .cheap)
        let cache = try filled(3)
        #expect(cache.memoryTraits == traits)
        #expect(cache.memoryUsage == MemoryUsage(footprintBytes: 3 * Self.imageBytes, entries: 3))
    }

    /// A cache of only copies (discarded pages' pictures, hidden pages' thumbnails) stays whole at warning:
    /// the warning level never makes lossy work act. It empties at critical, on the release slice.
    @Test func anOnlyCopyCacheStaysWholeAtWarning() throws {
        let traits = PreviewImageCache.onlyCopyTraits
        #expect(traits.isManaged && traits.retention == .lossy && traits.recreateCost == .expensive)
        #expect(MemoryLimitPolicy(mode: .aggressive).limit(for: traits, at: .warning) == .default)
        let kernel = ManualMemoryPressureSource()
        let slices = HeldSlices()
        let pressure = MemoryPressureEvents(source: kernel)
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: slices)
        let cache = try filled(4, contents: .onlyCopy)
        #expect(cache.memoryTraits == traits)
        cache.registerMemoryConsumer(name: "internal-page-pictures", with: coordinator)
        kernel.send(.warning)
        slices.runAll()
        #expect(cache.count == 4 && cache.capacityBytes == 4 * Self.imageBytes, "warning dropped only-copy pictures")
        kernel.send(.critical)
        slices.runAll()
        #expect(cache.count == 0)
        withExtendedLifetime((pressure, coordinator)) {}
    }

    /// With feature `purgeableImageCaches` off (the default allocator) the cache keeps the image
    /// itself, as before the feature: no copy and no color conversion, and all its bytes are footprint.
    @Test func aResidentCacheKeepsTheInsertedImageItself() async throws {
        let cache = PreviewImageCache(fullCapacityBytes: Self.imageBytes)
        let inserted = try image()
        let picture = await cache.picture(of: inserted)
        #expect(cache.insert(picture, for: "k"))
        #expect(cache.image(for: "k") === inserted, "the cache returned a copy, not the inserted image")
        #expect(cache.memoryUsage == MemoryUsage(footprintBytes: Self.imageBytes, entries: 1))
    }

    /// An insert copies no pixels on the main actor. A purgeable picture's copy is drawn off it,
    /// when the picture is made; the insert makes no pages; a picture the cache would refuse is never copied.
    @Test func anInsertCopiesNoPixelsOnTheMainActor() async throws {
        let fakes = FakePurgeableAllocations()
        let cache = PreviewImageCache(fullCapacityBytes: 2 * Self.imageBytes, allocator: fakes.allocator)
        let picture = try await cache.picture(of: image())
        #expect(fakes.pages.count == 1 && fakes.madeOnMain == 0, "the picture's pixels were copied on the main thread")
        #expect(cache.insert(picture, for: "k"))
        #expect(fakes.pages.count == 1, "the insert copied the pixels")
        let refused = try await cache.picture(of: image(side: 128))
        #expect(refused == nil && fakes.pages.count == 1, "a picture the cache refuses was copied")
    }

    /// A picture the kernel purged is a miss and leaves the cache (its bytes with it), so the
    /// owner pictures it again; the others stay readable.
    @Test func aPurgedPictureIsAMissAndLeavesTheCache() async throws {
        let fakes = FakePurgeableAllocations()
        let cache = PreviewImageCache(fullCapacityBytes: 3 * Self.imageBytes, allocator: fakes.allocator)
        for index in 0..<3 { cache.insert(try await cache.picture(of: image()), for: "k\(index)") }
        let pages = fakes.pages
        try #require(pages.count == 3 && pages.allSatisfy(\.isVolatile), "kept pictures are not volatile at rest")
        #expect(pages[1].purge())
        #expect(cache.image(for: "k1") == nil, "a purged picture was returned")
        #expect(cache.count == 2 && cache.totalBytes == 2 * Self.imageBytes, "a purged picture stayed in the cache")
        #expect(cache.image(for: "k0") != nil && cache.image(for: "k2") != nil)
        let again = try await cache.picture(of: image())
        #expect(cache.insert(again, for: "k1"), "the owner could not picture the key again")
        #expect(cache.image(for: "k1") != nil)
    }

    /// A picture is locked only while an image of it lives, and reads wrap the kept pixels (no
    /// new pages per read). The report splits locked (footprint) bytes from volatile ones, and a picture
    /// removed while drawn leaves the locked bytes at once.
    @Test func lockedAndVolatileBytesAreReportedApart() async throws {
        let fakes = FakePurgeableAllocations()
        let cache = PreviewImageCache(fullCapacityBytes: 3 * Self.imageBytes, allocator: fakes.allocator)
        for index in 0..<3 { cache.insert(try await cache.picture(of: image()), for: "k\(index)") }
        #expect(cache.memoryUsage == MemoryUsage(footprintBytes: 0, volatileBytes: 3 * Self.imageBytes, entries: 3))
        try withExtendedLifetime(try #require(cache.image(for: "k0"))) { _ in
            #expect(cache.memoryUsage == MemoryUsage(footprintBytes: Self.imageBytes, volatileBytes: 2 * Self.imageBytes, entries: 3))
            #expect(!fakes.pages[0].isVolatile && !fakes.pages[0].purge(), "a drawn picture could be purged")
            _ = cache.image(for: "k0")
            #expect(fakes.pages.count == 3, "a read made new pages: it copied the pixels")
            cache.remove("k0")
            #expect(cache.memoryUsage == MemoryUsage(footprintBytes: 0, volatileBytes: 2 * Self.imageBytes, entries: 2))
        }
        #expect(cache.memoryUsage == MemoryUsage(footprintBytes: 0, volatileBytes: 2 * Self.imageBytes, entries: 2))
        #expect(fakes.pages[0].isVolatile, "the last image's free left the pixels locked")
    }

    /// Through the app's coordinator: warning gives the medium mode's 25 %, critical empties it on the
    /// release slice, never in the pressure event's turn.
    @Test func followsTheCoordinatorsLimits() throws {
        let kernel = ManualMemoryPressureSource()
        let slices = HeldSlices()
        let pressure = MemoryPressureEvents(source: kernel)
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: slices)
        let cache = try filled(8)
        cache.registerMemoryConsumer(name: "preview-images", with: coordinator)
        #expect(cache.memoryLimit == .default)

        kernel.send(.warning)
        #expect(cache.capacityBytes == 2 * Self.imageBytes, "warning in medium mode is not a quarter")
        slices.runAll()
        #expect(cache.count == 2)

        kernel.send(.critical)
        #expect(cache.count == 2, "the critical limit freed images in the pressure event's turn")
        slices.runAll()
        #expect(cache.count == 0)
        withExtendedLifetime((pressure, coordinator)) {}
    }
}

/// Counts a slice's expiry checks: the slice expires after the first one.
private nonisolated final class ExpiryChecks: @unchecked Sendable {
    // Read and written only by the one slice that owns it, on the test's main actor.
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
