import AppKit
import CmuxNextActions
import CmuxNextBookmarks

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

// The native bookmarks bar (``BookmarksBarHostSource``): the registry's menus and the app's write.
extension AppServices: BookmarksBarHost {
    func bookmarkBarContextMenu(bookmark: String?) -> NSMenu? {
        // The bar belongs to a browser tab: Bookmark This Page there is available.
        guard let bookmark else { return registry.makeContextMenu(for: .bookmarksBar, implied: .browserFocused) }
        return registry.makeContextMenu(for: .bookmark, target: ActionTargetRef(kind: .bookmark, id: bookmark), implied: .browserFocused)
    }

    /// A drop or a move on the bar: the star's write, so the app's tree copy and last folder follow now.
    func bookmarkBarApply(_ operation: BookmarkOperation, profile: String) {
        do { try bookmarks.apply(operation, profile: profile) } catch { registry.refuse(BookmarkAppStrings.failure(error)) }
    }
}
