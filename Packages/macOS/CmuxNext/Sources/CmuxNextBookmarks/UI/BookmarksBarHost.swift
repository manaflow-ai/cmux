public import AppKit

/// What the bookmarks bar needs from the app beyond the Bookmarks page's host: the registry's
/// menus and the app's own bookmark write (``BookmarksBarHostSource``).
@MainActor
public protocol BookmarksBarHost: BookmarkPageHost {
    /// The registry's Bookmark menu for `bookmark` (nil: the Bookmarks Bar menu of the bar's empty area).
    func bookmarkBarContextMenu(bookmark: String?) -> NSMenu?
    /// Applies a drop or a move on the bar through the app's bookmark write, as every other
    /// bookmark edit in the app does (its copy of the tree and the last folder follow at once).
    /// A refused write says why.
    func bookmarkBarApply(_ operation: BookmarkOperation, profile: String)
}
