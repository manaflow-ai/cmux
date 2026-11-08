import AppKit
import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextPages

// The Bookmarks page (``BookmarkPageHostProvider``): one-line forwards to the bookmark service.
extension AppServices: BookmarkPageHost {
    func bookmarkProfile(ofTab key: String) -> String { bookmarks.profile(ofTab: key) }
    func bookmarkRows(_ ids: [String], profile: String) async throws -> [BookmarkNode] { try await bookmarks.routed.get(ids, profile: profile) }
    func bookmarkChildren(of id: String, profile: String) async throws -> [BookmarkNode] {
        try await bookmarks.routed.children(of: id, profile: profile, limit: 20_000)
    }
    var bookmarkFolderIconsSupported: Bool { bookmarks.supportsFolderIcons }
    func bookmarkFavicon(_ node: BookmarkNode, profile: String) -> CGImage? { bookmarks.favicon(of: node, profile: profile, fetching: true)?.cgImage }
    func bookmarkFolderIcon(_ node: BookmarkNode, side: CGFloat) -> NSImage? { bookmarks.folderIconImage(of: node, side: side, awaiting: true) }
    var bookmarkIconRevision: Int { favicons.revision &+ bookmarks.awaitedFolderIcons.count }
    func openBookmark(_ node: BookmarkNode, profile: String, disposition: BookmarkOpenDisposition, fromTab key: String) { BookmarkOpener(services: self).open(node, profile: profile, disposition: disposition, fromTab: key) }
}

// The bookmarks bar (``BookmarksBarProvider``): the registry's menus and refusals, and its pages.
extension AppServices: BookmarksBarHost {
    func bookmarkBarContextMenu(bookmark: String?, profile: String, isFolder: Bool, icon: String?) -> NSMenu? {
        // The bar belongs to a browser tab: Bookmark This Page there is available.
        guard let bookmark else { return registry.makeContextMenu(for: .bookmarksBar, implied: .browserFocused) }
        // The menu's rows and actions act on the row the bar drew, in the bar's profile.
        bookmarks.menuTarget = BookmarkService.MenuTarget(id: bookmark, profile: profile, isFolder: isFolder, icon: icon)
        return registry.makeContextMenu(for: .bookmark, target: ActionTargetRef(kind: .bookmark, id: bookmark), implied: .browserFocused)
    }

    func bookmarkBarRefused(_ message: String) { registry.refuse(message) }

    /// A drop or a move on the bar: the app's write to the home daemon; a drop makes the bar the last folder.
    func bookmarkBarApply(_ op: BookmarkRoutedClient.Op, profile: String) async throws {
        if op.json["op"]?.stringValue == "create" { bookmarks.lastFolder[profile] = BookmarkRoot.bar.rawValue }
        do { try await bookmarks.apply([op]) } catch {
            throw PageError(code: "cmux.bookmarks.refused", message: BookmarkAppStrings.failure(error))
        }
    }

    /// One bookmarks bar page, its tree from the daemon relay; ``BookmarksBarPages`` lends it to a tab.
    func bookmarksBarPage() -> BookmarksBarPage? {
        guard let page = BookmarksBarPage.make(host: self, relay: DaemonPageRelay(services: self)) else { return nil }
        PageConnectionWatch(page: page.view, store: machines.local.store).start()
        return page
    }
}
