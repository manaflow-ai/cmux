public import AppKit

extension BookmarksBarView {
    /// Bookmark `id`'s item on this bar in screen coordinates, for popups that
    /// open beside it (the App's icon picker). Nil when the bar is not in a
    /// window or `id` is not an item shown on it (inside a folder, or in the
    /// overflow menu).
    public func itemFrameOnScreen(_ id: String) -> NSRect? {
        guard let window, let item = barItems.first(where: { $0.node.id == id && !$0.isHidden }) else { return nil }
        return window.convertToScreen(item.convert(item.bounds, to: nil))
    }
}
