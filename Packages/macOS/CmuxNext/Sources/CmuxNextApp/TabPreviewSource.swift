import CmuxNextTabs
import CoreGraphics

/// Hover-card thumbnails: a live snapshot while the tab has a surface, else
/// the last preview kept in the 32 MB LRU.
final class TabPreviewSource: TabPreviewProvider {
    private unowned let cache: TabContentCache

    init(cache: TabContentCache) {
        self.cache = cache
    }

    func previewImage(for tab: TabID, maxPixelSize: CGSize) async -> CGImage? {
        await cache.previewImage(for: tab.rawValue, maxPixelSize: maxPixelSize)
    }
}
