public import AppKit

extension HomeSidebarView {
    /// The Unread filter's parts, in the Home list's coordinates (``HomeSidebarView/filterParts()``).
    public typealias FilterParts = (toggle: CGRect, chip: CGRect?, emptyList: CGRect)

    /// The Unread filter's parts as laid out now, in this view's coordinates (the Sidebar States Playground's Home
    /// filter section, Debug menu): the toggle, the on filter's "Unread ×" chip (nil while it is hidden), and the
    /// band under the header where an empty filtered list says No Unread Chats over Show All.
    ///
    /// Lays the list and its header out first, so a filter just turned on or off shows in the frames.
    /// - Returns: The toggle's frame, the chip's frame or nil, and the empty list's band.
    public func filterParts() -> FilterParts {
        let host = list.headerView
        layoutSubtreeIfNeeded()
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        list.layoutSubtreeIfNeeded()
        func frame(_ view: NSView) -> CGRect { convert(view.bounds, from: view) }
        // No Unread Chats sits 40 pt under the list's top and Show All 8 pt under it (MessagesLab's SidebarController).
        let band = convert(CGRect(x: 0, y: header.listTop, width: host.bounds.width, height: 116), from: host)
        return (frame(unreadToggle), filterChip.isHiddenOrHasHiddenAncestor ? nil : frame(filterChip), band)
    }
}
