public import AppKit

/// What the bookmarks bar and its folder menus read and do. The App fills
/// it from `BookmarkService` for one browser profile.
@MainActor
public protocol BookmarksBarSource: AnyObject {
    /// Children of `parent` (a root raw value or a folder id), in order.
    func bookmarkChildren(of parent: String) -> [BookmarkNode]
    /// The favicon for a node (a folder icon for folders), or nil.
    func favicon(for node: BookmarkNode) -> NSImage?
    func open(_ node: BookmarkNode, disposition: BookmarkOpenDisposition)
    /// Opens every bookmark directly in `folder` in new tabs.
    func openAll(in folder: String)
    /// Moves `id` to `index` among the bar's children (final position).
    func moveToBar(_ id: String, index: Int)
    /// A page dragged onto the bar: bookmark it at `index`.
    func addToBar(url: URL, title: String, index: Int)
    /// The context menu for `node` (nil: the bar's empty area).
    func contextMenu(for node: BookmarkNode?) -> NSMenu?
}
