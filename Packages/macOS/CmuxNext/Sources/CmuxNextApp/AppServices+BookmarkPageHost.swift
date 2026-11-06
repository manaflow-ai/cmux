import AppKit
import CmuxNextBookmarks

// The Bookmarks page (``BookmarkPageHostProvider``): one-line forwards to the bookmark service.
extension AppServices: BookmarkPageHost {
    func bookmarkProfile(ofTab key: String) -> String { bookmarks.profile(ofTab: key) }
    func bookmarkTree(_ profile: String) -> BookmarkTree { bookmarks.tree(profile) }
    var bookmarkFolderIconsSupported: Bool { bookmarks.supportsFolderIcons }
    func bookmarkFavicon(_ node: BookmarkNode, profile: String) -> CGImage? { bookmarks.favicon(of: node, profile: profile, fetching: true)?.cgImage }
    func bookmarkFolderIcon(_ node: BookmarkNode, side: CGFloat) -> NSImage? { bookmarks.folderIconImage(of: node, side: side, awaiting: true) }
    var bookmarkIconRevision: Int { favicons.revision &+ bookmarks.awaitedFolderIcons.count }
    func openBookmark(_ node: BookmarkNode, profile: String, disposition: BookmarkOpenDisposition, fromTab key: String) { BookmarkOpener(services: self).open(node, profile: profile, disposition: disposition, fromTab: key) }
    func openAllBookmarks(in folder: String, profile: String, fromTab key: String) { BookmarkOpener(services: self).openAll(in: folder, profile: profile, fromTab: key) }
}
