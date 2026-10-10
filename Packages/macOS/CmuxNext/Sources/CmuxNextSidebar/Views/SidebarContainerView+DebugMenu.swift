public import AppKit

extension SidebarContainerView {
    /// `debug.sidebar_rows` `menu_x`/`menu_y`: the menu a right-click at a
    /// window point (from the top-left, as `debug.mouse`) opens, from the list's
    /// own `menu(for:)` (so the App's provider builds it), never shown.
    public func debugMenu(atWindowPoint windowPoint: CGPoint) -> NSMenu? {
        let list = sidebarView.list
        guard let window = list.window else { return nil }
        let height = window.contentView?.bounds.height ?? window.frame.height
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: windowPoint.x, y: height - windowPoint.y),
                                             modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
        return list.menu(for: event)
    }
}
