import CmuxNextMemory
import Testing

/// The content cache's image caches take shares of `SubsystemBudget.imageCacheBytes` (p07-memory-058):
/// at 16 GB at least the literals they replaced (previews 32 MB, page thumbnails 16 MB), within the budget
/// with the tab strip thumbnails' 48 MB.
struct ImageCacheSharesTests {
    @Test func sixteenGigabyteSharesAreAtLeastTheOldLiterals() {
        let budget = SubsystemBudget.forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false)
        let shares = ImageCacheShares(budget)
        #expect(shares.previewBytes >= 32 << 20, "previews got \(shares.previewBytes >> 20) MiB, under the old 32 MB")
        #expect(shares.pageThumbnailBytes >= 16 << 20, "page thumbnails got \(shares.pageThumbnailBytes >> 20) MiB, under the old 16 MB")
        #expect(shares.previewBytes + shares.pageThumbnailBytes + (48 << 20) <= budget.imageCacheBytes)
    }

    @Test(arguments: [8, 24, 32, 64, 128] as [UInt64])
    func sharesScaleWithTheBudget(gigabytes: UInt64) {
        let budget = SubsystemBudget.forMemory(physicalBytes: gigabytes << 30, gpuResidentAvailable: false)
        let shares = ImageCacheShares(budget)
        #expect(shares.previewBytes == budget.imageCacheBytes / 4)
        #expect(shares.pageThumbnailBytes == budget.imageCacheBytes / 8)
    }
}
