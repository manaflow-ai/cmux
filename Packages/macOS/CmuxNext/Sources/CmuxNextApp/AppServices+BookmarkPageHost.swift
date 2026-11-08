import AppKit
import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextPages

// The Bookmarks page (``BookmarkPageHostProvider``): one-line forwards to the bookmark service.
extension AppServices: BookmarkPageHost {
    func bookmarkProfile(ofTab key: String) -> String { bookmarks.profile(ofTab: key) }
    func bookmarkTree(_ profile: String) -> BookmarkTree { bookmarks.tree(profile) }
    func bookmarkOwnerTree(_ profile: String) async throws -> BookmarkTree { try await bookmarks.routed.tree(profile: profile) }
    var bookmarkFolderIconsSupported: Bool { bookmarks.supportsFolderIcons }
    func bookmarkFavicon(_ node: BookmarkNode, profile: String) -> CGImage? { bookmarks.favicon(of: node, profile: profile, fetching: true)?.cgImage }
    func bookmarkFolderIcon(_ node: BookmarkNode, side: CGFloat) -> NSImage? { bookmarks.folderIconImage(of: node, side: side, awaiting: true) }
    var bookmarkIconRevision: Int { favicons.revision &+ bookmarks.awaitedFolderIcons.count }
    func openBookmark(_ node: BookmarkNode, profile: String, disposition: BookmarkOpenDisposition, fromTab key: String) { BookmarkOpener(services: self).open(node, profile: profile, disposition: disposition, fromTab: key) }
}

// The bookmarks bar (``BookmarksBarProvider``): the registry's menus and refusals, and its pages.
extension AppServices: BookmarksBarHost {
    func bookmarkBarContextMenu(bookmark: String?) -> NSMenu? {
        // The bar belongs to a browser tab: Bookmark This Page there is available.
        guard let bookmark else { return registry.makeContextMenu(for: .bookmarksBar, implied: .browserFocused) }
        return registry.makeContextMenu(for: .bookmark, target: ActionTargetRef(kind: .bookmark, id: bookmark), implied: .browserFocused)
    }

    func bookmarkBarRefused(_ message: String) { registry.refuse(message) }

    /// One bookmarks bar page: the tree to the daemon relay, `cmux.bookmarkPage.` to its host and
    /// `cmux.bookmarksBar.` to the bar provider. ``BookmarksBarPages`` lends it to a tab.
    func bookmarksBarPage() -> BookmarksBarPage? {
        let host = BookmarkPageHostProvider(host: self, tabKey: "")
        let bar = BookmarksBarProvider(host: self, pageHost: host)
        let routes = [PageRoute(prefix: "cmux.bookmarks.", provider: DaemonPageRelay(services: self)),
                      PageRoute(prefix: BookmarkPageHostProvider.prefix, provider: host),
                      PageRoute(prefix: BookmarksBarProvider.prefix, provider: bar)]
        guard let view = PageWebView(descriptor: .bookmarksBar, routes: routes, options: BookmarksBarPage.engineOptions) else { return nil }
        // The bar never takes the keys from the page or the omnibar (the native bar's items did not).
        view.refusesKeyFocus = true
        view.followsUIScale = false
        bar.page = view
        PageConnectionWatch(page: view, store: machines.local.store).start()
        return BookmarksBarPage(view: view, host: host, bar: bar)
    }
}
