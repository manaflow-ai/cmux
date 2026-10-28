public import CmuxNextCompat

/// The full sizes of the app content cache's picture stores (plans/cmux-next/chrome-parity/p07-memory.md,
/// task 058).
///
/// Budgeted (`memoryImageCaches` on), they are shares of `SubsystemBudget`. The decoded image caches share
/// `imageCacheBytes`, M / 128 MiB (128 MiB on a 16 GB Mac): terminal previews take a quarter and page
/// thumbnails an eighth, which on a 16 GB Mac is exactly the 32 MB and 16 MB they had as literals; discarded
/// internal pages' pictures (which shared the previews' 32 MB before) take a quarter; the 3/8 left is the
/// tab strip thumbnails' share (`TabThumbnailCache`, 48 MB today, task 052). Hibernated pages' pictures take
/// `hibernationSnapshotBytes`. With the feature off they keep the fixed sizes they had before (``legacy``),
/// whatever the Mac's memory. These are the sizes at the default limit; the memory coordinator scales them
/// under pressure.
///
/// ``purgeable`` (`purgeableImageCaches`, task 107) says where the stores and the hover cards keep their pixels:
/// purgeable virtual memory, volatile whenever nothing draws them, else resident heap memory.
public nonisolated struct ImageCacheShares: Hashable, Sendable {
    /// `TabContentCache.previews`' full size (terminal previews).
    public let previewBytes: Int
    /// `TabContentCache.pageThumbnails`' full size.
    public let pageThumbnailBytes: Int
    /// `TabContentCache.internalPagePictures`' full size (discarded internal pages' last pictures).
    public let internalPagePictureBytes: Int
    /// `BrowserHibernation.snapshots`' full size (hibernated pages' pictures).
    public let hibernationSnapshotBytes: Int
    /// Whether the pictures' pages are purgeable (`purgeableImageCaches`); false keeps them resident.
    public private(set) var purgeable = false

    /// Makes the pictures' pages: ``PurgeableAllocator/virtualMemory`` when ``purgeable``, else resident ones.
    public var pictureAllocator: PurgeableAllocator { purgeable ? .virtualMemory : .resident }

    /// The fixed sizes from before the budget: previews 32 MB, page thumbnails 16 MB, the hibernation
    /// pictures 64 MB, and discarded internal pages' pictures the 32 MB they shared with the previews.
    public static let legacy = ImageCacheShares(
        previewBytes: 32 << 20, pageThumbnailBytes: 16 << 20, internalPagePictureBytes: 32 << 20,
        hibernationSnapshotBytes: 64 << 20)

    /// The shares of `budget`.
    ///
    /// - Parameter budget: This Mac's memory budget.
    public init(_ budget: SubsystemBudget) {
        self.init(previewBytes: budget.imageCacheBytes / 4, pageThumbnailBytes: budget.imageCacheBytes / 8,
                  internalPagePictureBytes: budget.imageCacheBytes / 4,
                  hibernationSnapshotBytes: budget.hibernationSnapshotBytes)
    }

    /// The shares of `budget` when `budgeted` (the `memoryImageCaches` feature), ``legacy`` otherwise.
    ///
    /// - Parameters:
    ///   - budget: This Mac's memory budget.
    ///   - budgeted: Whether the stores take their shares of it.
    ///   - purgeable: Whether the pictures' pages are purgeable (the `purgeableImageCaches` feature).
    public init(_ budget: SubsystemBudget, budgeted: Bool, purgeable: Bool = false) {
        self = budgeted ? ImageCacheShares(budget) : .legacy
        self.purgeable = purgeable
    }

    /// Explicit sizes (tests).
    ///
    /// - Parameters:
    ///   - previewBytes: The previews' full size.
    ///   - pageThumbnailBytes: The page thumbnails' full size.
    ///   - internalPagePictureBytes: The discarded internal pages' pictures' full size.
    ///   - hibernationSnapshotBytes: The hibernation pictures' full size.
    public init(previewBytes: Int, pageThumbnailBytes: Int, internalPagePictureBytes: Int, hibernationSnapshotBytes: Int) {
        self.previewBytes = previewBytes
        self.pageThumbnailBytes = pageThumbnailBytes
        self.internalPagePictureBytes = internalPagePictureBytes
        self.hibernationSnapshotBytes = hibernationSnapshotBytes
    }
}
