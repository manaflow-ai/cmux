import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextTabs
import CoreGraphics

/// Hover-card thumbnails: a live snapshot while the tab has a surface, else
/// the last preview kept in the 32 MB LRU. The New Tab and blank pages
/// picture nothing (a flat page in the theme background), and neither does a
/// flat capture (a page that had not painted): the card shows no thumbnail.
final class TabPreviewSource: TabPreviewProvider {
    private unowned let cache: TabContentCache

    init(cache: TabContentCache) {
        self.cache = cache
    }

    func previewImage(for tab: TabID, maxPixelSize: CGSize) async -> CGImage? {
        if let page = cache.browsers[tab.rawValue]?.tab, BrowserNewTabPage.isNewTabPage(page.state.url) { return nil }
        guard let image = await cache.previewImage(for: tab.rawValue, maxPixelSize: maxPixelSize) else { return nil }
        return await ThumbnailStats.measure(image)?.isBlank == true ? nil : image
    }
}
