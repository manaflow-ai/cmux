@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextMemory
import CoreGraphics
import Testing

/// Tab previews and page thumbnails are sized from the image cache budget and follow the memory
/// coordinator as lossless consumers (p07-memory-058): a limit lowers the cap and frees nothing, the
/// release slice drops the oldest images down to it, and the critical limit empties the cache.
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

    private static let imageBytes = 64 * 64 * 4

    private func filled(_ count: Int) throws -> PreviewImageCache {
        let cache = PreviewImageCache(fullCapacityBytes: count * Self.imageBytes)
        for index in 0..<count { cache.insert(try image(), for: "k\(index)") }
        return cache
    }

    private func release(_ cache: PreviewImageCache, to limit: MemoryLimit) -> MemoryReleaseProgress {
        cache.releaseMemory(within: MemoryReleaseSlice(limit: limit) { false })
    }

    @Test func sixteenGigabyteSharesAreAtLeastTheOldLiterals() {
        let shares = ImageCacheShares(.forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false))
        #expect(shares.previewBytes >= 32 << 20, "previews got \(shares.previewBytes >> 20) MiB, under the old 32 MB")
        #expect(shares.pageThumbnailBytes >= 16 << 20, "page thumbnails got \(shares.pageThumbnailBytes >> 20) MiB, under the old 16 MB")
        let budget = SubsystemBudget.forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false)
        #expect(shares.previewBytes + shares.pageThumbnailBytes <= budget.imageCacheBytes)
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
        cache.insert(try image(), for: "new")
        #expect(cache.count == 4, "an insert under the half limit grew past the halved capacity")
    }

    @Test func theCriticalLimitEmptiesTheCacheAndKeepsNothingNew() throws {
        let cache = try filled(5)
        cache.updateMemoryLimit(.criticalThreshold)
        #expect(release(cache, to: .criticalThreshold) == .done)
        #expect(cache.count == 0 && cache.totalBytes == 0, "the critical limit left \(cache.count) previews")
        cache.insert(try image(), for: "late")
        #expect(cache.count == 0, "a preview was kept at the critical limit")
        cache.updateMemoryLimit(.default)
        cache.insert(try image(), for: "back")
        #expect(cache.count == 1, "the cache kept nothing after the limit came back")
    }

    @Test func anExpiredSliceAsksForMoreTurns() throws {
        let cache = try filled(4)
        let checks = ExpiryChecks()
        let slice = MemoryReleaseSlice(limit: .criticalThreshold) { checks.next() > 1 }
        #expect(cache.releaseMemory(within: slice) == .more)
        #expect(cache.count == 3, "a slice dropped more than its time allowed")
    }

    @Test func registersAsALosslessCheapManagedConsumerAndReportsItsBytes() throws {
        let traits = PreviewImageCache.memoryTraits
        #expect(traits.isManaged && traits.retention == .lossless && traits.dataAccess == .none && traits.recreateCost == .cheap)
        let cache = try filled(3)
        #expect(cache.memoryUsage == MemoryUsage(footprintBytes: 3 * Self.imageBytes, entries: 3))
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
