import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextTabs
import CmuxNextWakeups
import Foundation

/// Bookmark favicons on the bars and in their menus (cx-d0d.37): the icon an open tab on
/// the bookmark's site shows, else the site's `/favicon.ico`, fetched through the tab
/// favicon store. A bar that drew a stand-in for an icon still loading redraws when it lands.
extension BookmarkService {
    /// The favicon of bookmark `node` for the bar of tab `tabKey` (that tab's browser
    /// profile), nil for a folder, while it loads, or without one.
    func favicon(of node: BookmarkNode, tabKey: String) -> TabImage? {
        guard let address = faviconAddress(of: node) else { return nil }
        return services.favicons.image(for: address, profile: services.browserProfiles.engineProfile(forTab: tabKey))
    }

    /// The favicon of `node` in bookmark profile `profile` (the manager page's rows, which
    /// fetch it, and Open Bookmark…, which only takes one already here). Reads the store's
    /// revision, so a view drawn from it redraws when an icon lands.
    func favicon(of node: BookmarkNode, profile: String, fetching: Bool) -> TabImage? {
        _ = services.favicons.revision
        guard let address = faviconAddress(of: node) else { return nil }
        let engine = BrowserProfileRecord.engineProfile(for: profile) ?? .default
        return fetching ? services.favicons.image(for: address, profile: engine) : services.favicons.cachedImage(for: address, profile: engine)
    }

    /// True while the icon of `node` for tab `tabKey`'s bar is being fetched.
    func isFetchingFavicon(of node: BookmarkNode, tabKey: String) -> Bool {
        guard let address = faviconAddress(of: node) else { return false }
        return services.favicons.isFetching(address, profile: services.browserProfiles.engineProfile(forTab: tabKey))
    }

    /// Redraws the bars that wait on an icon when one lands (no polling). A service observation: it fans out
    /// to every chrome's bar, none of which owns it, and each bar redraws through its tab's node
    /// (``reloadBar(_:)``), so a hidden one waits for its show. `visible`: the icons show on the bars.
    func followFavicons() {
        let favicons = services.favicons
        faviconObservation = ServiceObservation(.visible, owner: "BookmarkService.favicons", on: services.mainWork) {
            favicons.revision
        } apply: { [weak self] _ in
            self?.reloadBarsAwaitingIcons()
        }
    }

    /// Redraws the bars that drew a stand-in for an icon still loading.
    func reloadBarsAwaitingIcons() {
        guard showsBar else { return }
        for chrome in chromes.values where chrome.source.awaitsFavicons { reloadBar(chrome) }
    }

    /// The favicon URL of a bookmark (``AppServices/siteFaviconAddress(origin:)``).
    private func faviconAddress(of node: BookmarkNode) -> String? {
        guard !node.isFolder, let origin = node.faviconKey ?? node.url.flatMap(BookmarkURL.faviconKey(for:)) else { return nil }
        return services.siteFaviconAddress(origin: origin)
    }
}
