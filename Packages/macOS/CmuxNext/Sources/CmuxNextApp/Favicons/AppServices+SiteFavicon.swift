import AppKit
import CmuxNextBookmarks
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTabs
import Foundation

/// Favicons of pages that are not open tabs (a bookmark, a recent page) and favicons as a
/// cmux page draws them (cx-d0d.8).
extension AppServices: OpenTabFaviconSource {
    /// The favicon URL of the site at `origin` (`https://host[:port]`): the icon an open, not incognito, browser tab on
    /// that origin shows, else the origin's `/favicon.ico`. One read of the kept table, no walk: after a change of an open
    /// tab it has the new answer some main actor turns later. Its one workspace for the site is asked if it is incognito now.
    func siteFaviconAddress(origin: String) -> String { openTabFaviconTable.address(origin: origin) { windows.isIncognito(workspace: $0) } }
    /// The app's one table of open tab favicons (the sidebar document holds it), started at its first ask over this Mac's store.
    var openTabFaviconTable: OpenTabFavicons { sidebarDoc.openTabFavicons.started(over: machines.local.store, from: self) }

    /// The favicon address an open (not incognito) browser tab shows, by the tab's site origin (`BookmarkURL.faviconKey`),
    /// the first tab per origin as `siteFaviconAddress` picks it; the site's own `/favicon.ico` is left out (a link
    /// draws that one without storing it). One scan of the tabs, for a one-shot read (the debug rows); the sidebar
    /// links follow ``OpenTabFavicons``.
    func openTabFaviconsByOrigin() -> [String: String] {
        OpenTabFavicons.table(machines.local.store.workspaces.map { openTabFavicons(of: $0) })
    }

    /// `workspace`'s open tab favicons as the sidebar links get them (none for an incognito window's), incognito read once from the workspace's own facts.
    func openTabFavicons(of workspace: WorkspaceModel) -> [OpenTabFavicons.Favicon] {
        OpenTabFavicons.favicons(of: workspace, incognito: windows.isIncognito(workspace: workspace), faviconKey: BookmarkURL.faviconKey(for:))
    }

    /// The favicon of the page at `url` for `profile`, nil while it loads or without one.
    func siteFavicon(_ url: URL, profile: BrowserProfileID) -> TabImage? {
        guard let origin = BookmarkURL.faviconKey(for: url) else { return nil }
        return favicons.face(for: siteFaviconAddress(origin: origin), profile: profile, origin: origin)
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
