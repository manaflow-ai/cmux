import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextTabs
import Foundation

/// Bookmark favicons on the bars and in their menus (cx-d0d.37): the icon an open tab on
/// the bookmark's site shows, else the site's `/favicon.ico`, fetched through the tab
/// favicon store. A bar that drew a stand-in rebuilds when the icon lands, and the manager page
/// asks again (``AppServices/bookmarkIconRevision``).
extension BookmarkService {
    /// The favicon of `node` in bookmark profile `profile` (the manager page's rows, which
    /// fetch it, and Open Bookmark…, which only takes one already here). Reads the store's
    /// revision, so a view drawn from it redraws when an icon lands.
    func favicon(of node: BookmarkNode, profile: String, fetching: Bool) -> TabImage? {
        _ = services.favicons.revision
        guard let address = faviconAddress(of: node) else { return nil }
        let engine = BrowserProfileRecord.engineProfile(for: profile) ?? .default
        return fetching ? services.favicons.image(for: address, profile: engine) : services.favicons.cachedImage(for: address, profile: engine)
    }

    /// The favicon URL of a bookmark (``AppServices/siteFaviconAddress(origin:)``).
    private func faviconAddress(of node: BookmarkNode) -> String? {
        guard !node.isFolder, let origin = node.faviconKey ?? node.url.flatMap(BookmarkURL.faviconKey(for:)) else { return nil }
        return services.siteFaviconAddress(origin: origin)
    }
}
