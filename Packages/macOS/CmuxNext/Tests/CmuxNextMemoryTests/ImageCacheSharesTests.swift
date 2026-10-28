import CmuxNextCompat
import CmuxNextMemory
import Testing

/// The content cache's picture stores take shares of `SubsystemBudget` with `memoryImageCaches` on:
/// at 16 GB at least the literals they replaced (previews 32 MB, page thumbnails 16 MB,
/// hibernation pictures 64 MB), within the image budget with the tab strip thumbnails' 48 MB. With the
/// feature off every Mac keeps the fixed sizes.
struct ImageCacheSharesTests {
    @Test func sixteenGigabyteSharesAreAtLeastTheOldLiterals() {
        let budget = SubsystemBudget.forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false)
        let shares = ImageCacheShares(budget)
        let legacy = ImageCacheShares.legacy
        #expect(shares.previewBytes >= legacy.previewBytes, "previews got \(shares.previewBytes >> 20) MiB, under the old 32 MB")
        #expect(shares.pageThumbnailBytes >= legacy.pageThumbnailBytes,
                "page thumbnails got \(shares.pageThumbnailBytes >> 20) MiB, under the old 16 MB")
        #expect(shares.internalPagePictureBytes >= legacy.internalPagePictureBytes)
        #expect(shares.hibernationSnapshotBytes >= legacy.hibernationSnapshotBytes)
        #expect(shares.previewBytes + shares.pageThumbnailBytes + shares.internalPagePictureBytes + (48 << 20) <= budget.imageCacheBytes)
    }

    @Test(arguments: [8, 24, 32, 64, 128] as [UInt64])
    func sharesScaleWithTheBudget(gigabytes: UInt64) {
        let budget = SubsystemBudget.forMemory(physicalBytes: gigabytes << 30, gpuResidentAvailable: false)
        let shares = ImageCacheShares(budget, budgeted: true)
        #expect(shares.previewBytes == budget.imageCacheBytes / 4)
        #expect(shares.pageThumbnailBytes == budget.imageCacheBytes / 8)
        #expect(shares.internalPagePictureBytes == budget.imageCacheBytes / 4)
        #expect(shares.hibernationSnapshotBytes == budget.hibernationSnapshotBytes)
    }

    /// The feature off changes no size on any Mac: an 8 GB Mac's budget shares are half the old sizes.
    @Test(arguments: [8, 16, 128] as [UInt64])
    func theFeatureOffKeepsTheFixedSizes(gigabytes: UInt64) {
        let budget = SubsystemBudget.forMemory(physicalBytes: gigabytes << 30, gpuResidentAvailable: false)
        let shares = ImageCacheShares(budget, budgeted: false)
        #expect(shares == .legacy)
        #expect(shares.previewBytes == 32 << 20 && shares.pageThumbnailBytes == 16 << 20)
        #expect(shares.hibernationSnapshotBytes == 64 << 20)
    }

    /// `purgeableImageCaches` picks where the pictures' pages come from: purgeable virtual
    /// memory when on, resident heap pages when off (the default, so the sizes and the report stay as before).
    @Test func thePurgeableFeaturePicksThePicturesPages() throws {
        let budget = SubsystemBudget.forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false)
        let off = ImageCacheShares(budget, budgeted: true)
        let on = ImageCacheShares(budget, budgeted: true, purgeable: true)
        #expect(!off.purgeable && !ImageCacheShares.legacy.purgeable)
        #expect(on.purgeable && on.previewBytes == off.previewBytes)
        let onPages = try #require(on.pictureAllocator.pages(byteCount: 16 << 10))
        let offPages = try #require(off.pictureAllocator.pages(byteCount: 16 << 10))
        #expect(onPages.isPurgeable && !offPages.isPurgeable)
    }
}
