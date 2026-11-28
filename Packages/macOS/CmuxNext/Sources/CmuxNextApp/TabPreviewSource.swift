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
        await Self.shown(cache.previewImage(for: tab.rawValue, maxPixelSize: maxPixelSize), key: tab.rawValue, cache: cache)
    }

    /// What a tab or screen card or a drag ghost pictures of `key`'s `image`: a page's,
    /// unless it is on the New Tab or blank page or the capture is flat; a terminal's as it is.
    static func shown(_ image: CGImage?, key: String, cache: TabContentCache) async -> CGImage? {
        let page = cache.browsers[key]?.tab
        if let page, BrowserNewTabPage.isNewTabPage(page.state.url) { return nil }
        guard let image, page != nil || cache.pageThumbnails.image(for: key) != nil else { return image }
        return await ThumbnailStats.measure(image)?.isBlank == true ? nil : image
    }
}
