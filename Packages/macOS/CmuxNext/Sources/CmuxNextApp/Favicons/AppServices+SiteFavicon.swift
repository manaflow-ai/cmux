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
    /// not incognito, browser tab on that origin shows, else the origin's `/favicon.ico`.
    func siteFaviconAddress(origin: String) -> String {
        let tabs = machines.local.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        let open = tabs.first { tab in
            tab.kind == .browser && tab.faviconURL != nil && !cache.browserTabs.isIncognitoTab(tab.id)
                && tab.url.flatMap(URL.init(string:)).flatMap(BookmarkURL.faviconKey(for:)) == origin
        }
        return open?.faviconURL ?? origin + "/favicon.ico"
    }

    /// The favicon address an open (not incognito) browser tab shows, by the tab's site origin (`BookmarkURL.faviconKey`),
    /// the first tab per origin as `siteFaviconAddress` picks it; the site's own `/favicon.ico` is left out (a link
    /// draws that one without storing it). One scan of the tabs for every link (sidebar links store these).
    func openTabFaviconsByOrigin() -> [String: String] {
        var byOrigin: [String: String] = [:]
        for tab in machines.local.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs) {
            guard tab.kind == .browser, let favicon = tab.faviconURL, !cache.browserTabs.isIncognitoTab(tab.id),
                  let origin = tab.url.flatMap(URL.init(string:)).flatMap(BookmarkURL.faviconKey(for:)), byOrigin[origin] == nil
            else { continue }
            byOrigin[origin] = favicon
        }
        return byOrigin.filter { $0.value != $0.key + "/favicon.ico" }
    }

    /// The favicon of the page at `url` for `profile`, nil while it loads or without one.
    /// `openTabs`: ``openTabFaviconsByOrigin()`` read once for a list of pages (a New Tab page's
    /// recent pages), so each page costs a lookup instead of a scan of every open tab.
    func siteFavicon(_ url: URL, profile: BrowserProfileID, openTabs: [String: String]? = nil) -> TabImage? {
        guard let origin = BookmarkURL.faviconKey(for: url) else { return nil }
        let address = openTabs.map { $0[origin] ?? origin + "/favicon.ico" } ?? siteFaviconAddress(origin: origin)
        return favicons.image(for: address, profile: profile)
    }

    /// Browser tab `tab`'s favicon as it is drawn in the strip (never an incognito tab's record).
    func tabFavicon(_ tab: TabModel) -> TabImage? {
        browserFavicon(key: tab.id, recordFavicon: cache.browserTabs.isIncognitoTab(tab.id) ? nil : tab.faviconURL)
    }
}
