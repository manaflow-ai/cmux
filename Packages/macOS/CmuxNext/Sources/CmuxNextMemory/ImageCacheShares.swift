/// The app content cache's decoded image caches' shares of `SubsystemBudget.imageCacheBytes`
/// (plans/cmux-next/chrome-parity/p07-memory.md, task 058).
///
/// The budget is one pool for every macOS decoded image cache, M / 128 MiB (128 MiB on a 16 GB Mac).
/// Tab previews take a quarter and page thumbnails an eighth, which on a 16 GB Mac is exactly the
/// 32 MB and 16 MB they had as literals; the 3/8 left is the tab strip thumbnails' share
/// (`TabThumbnailCache`, 48 MB today, task 052), and the last quarter is headroom. These are the sizes
/// at the default limit; the memory coordinator scales them under pressure.
public nonisolated struct ImageCacheShares: Hashable, Sendable {
    /// `TabContentCache.previews`' full size (terminal previews, discarded pages' pictures).
    public let previewBytes: Int
    /// `TabContentCache.pageThumbnails`' full size.
    public let pageThumbnailBytes: Int

    /// The shares of `budget`'s image cache bytes.
    ///
    /// - Parameter budget: This Mac's memory budget.
    public init(_ budget: SubsystemBudget) {
        self.init(previewBytes: budget.imageCacheBytes / 4, pageThumbnailBytes: budget.imageCacheBytes / 8)
    }

    /// Explicit sizes (tests).
    ///
    /// - Parameters:
    ///   - previewBytes: The previews' full size.
    ///   - pageThumbnailBytes: The page thumbnails' full size.
    public init(previewBytes: Int, pageThumbnailBytes: Int) {
        self.previewBytes = previewBytes
        self.pageThumbnailBytes = pageThumbnailBytes
    }
}
