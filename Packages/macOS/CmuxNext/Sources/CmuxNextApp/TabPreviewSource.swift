import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextTabs
import CoreGraphics

/// Hover-card thumbnails: a live snapshot while the tab has a surface, else
/// the last preview kept in the 32 MB LRU. The New Tab and blank pages
/// picture nothing (a flat page in the theme background), and neither does a
/// flat capture (a page that had not painted, a terminal with only its prompt):
/// the card shows no thumbnail.
final class TabPreviewSource: TabPreviewProvider {
    private unowned let cache: TabContentCache

    init(cache: TabContentCache) {
        self.cache = cache
    }

    func previewImage(for tab: TabID, maxPixelSize: CGSize) async -> CGImage? {
        await Self.shown(cache.previewImage(for: tab.rawValue, maxPixelSize: maxPixelSize), key: tab.rawValue, cache: cache)
    }

    /// What a tab or screen card or a drag ghost pictures of `key`'s `image`: nothing on the
    /// New Tab page, and nothing for a flat capture, a page's or a terminal's (a shell showing
    /// only its prompt over a see-through background pictured as an empty gray well, Leo
    /// 2026-10-20).
    static func shown(_ image: CGImage?, key: String, cache: TabContentCache) async -> CGImage? {
        if let page = cache.browsers[key]?.tab, BrowserNewTabPage.isNewTabPage(page.state.url) { return nil }
        guard let image else { return nil }
        return await ThumbnailStats.measure(image)?.isBlank == true ? nil : image
    }
}
