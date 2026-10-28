import AppKit
import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTabs
import Foundation

/// Favicons of pages that are not open tabs (a bookmark, a recent page) and favicons as a
/// cmux page draws them (cx-d0d.8).
extension AppServices {
    /// The favicon URL of the site at `origin` (`https://host[:port]`): the icon an open,
    /// not incognito, browser tab on that origin shows (the first by tab id), else the origin's `/favicon.ico`.
    /// Reads the open tabs of that origin only (`BrowserTabsBySite`), never the tree.
    func siteFaviconAddress(origin: String) -> String {
        openFavicon(openTabSiteFavicons.tabs(at: origin)) ?? origin + "/favicon.ico"
    }

    /// The favicon address an open (not incognito) browser tab shows, by the tab's site origin (`BookmarkURL.faviconKey`),
    /// the tab per origin `siteFaviconAddress` picks; the site's own `/favicon.ico` is left out (a link draws that one
    /// without storing it). Costs the open browser tabs, not the tree (sidebar links store these).
    func openTabFaviconsByOrigin() -> [String: String] {
        var byOrigin: [String: String] = [:]
        for (origin, tabs) in openTabSiteFavicons.bySite() {
            guard let favicon = openFavicon(tabs), favicon != origin + "/favicon.ico" else { continue }
            byOrigin[origin] = favicon
        }
        return byOrigin
    }

    /// The site a favicon is keyed by (`BookmarkURL.faviconKey`) of a tab's address; the open tabs are filed by it.
    nonisolated static func faviconSite(_ address: String) -> String? {
        URL(string: address).flatMap(BookmarkURL.faviconKey(for:))
    }

    /// The favicon of the first of `tabs` (the local store's browser tabs) that shows one and is not incognito. The
    /// incognito check reads the workspace the store's index filed the tab in (`StoreTabRoles.workspaceID(ofBrowser:)`)
    /// and the window registry, not a lookup of the tab (`isIncognitoTab` observes every tab list).
    private func openFavicon(_ tabs: [TabModel]) -> String? {
        let roles = machines.local.store.tabRoles
        return tabs.first { tab in
            guard tab.kind == .browser, tab.faviconURL != nil else { return false }
            return !(roles.workspaceID(ofBrowser: tab).map { windows.isIncognito(workspace: $0) } ?? false)
        }?.faviconURL
    }

    /// The favicon of the page at `url` for `profile`, nil while it loads or without one.
    func siteFavicon(_ url: URL, profile: BrowserProfileID) -> TabImage? {
        guard let origin = BookmarkURL.faviconKey(for: url) else { return nil }
        return favicons.image(for: siteFaviconAddress(origin: origin), profile: profile)
    }

    /// Browser tab `tab`'s favicon as it is drawn in the strip (never an incognito tab's record).
    func tabFavicon(_ tab: TabModel) -> TabImage? {
        browserFavicon(key: tab.id, recordFavicon: cache.browserTabs.isIncognitoTab(tab.id) ? nil : tab.faviconURL)
    }

    /// `image` as the inline image a cmux page may draw (its CSP allows `img-src data:` only).
    static func dataURL(_ image: TabImage?) -> String? {
        guard let image, let png = NSBitmapImageRep(cgImage: image.cgImage).representation(using: .png, properties: [:])
        else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
