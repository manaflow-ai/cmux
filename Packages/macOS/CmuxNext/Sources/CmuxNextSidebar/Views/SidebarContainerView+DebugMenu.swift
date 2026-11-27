public import AppKit

extension SidebarContainerView {
    /// `debug.sidebar_rows` `menu_x`/`menu_y`: the menu a right-click at a
    /// window point (from the top-left, as `debug.mouse`) opens, never shown:
    /// a layout item's menu (a workspace tile, a top row, Home) when an item
    /// of a band or a document block is there, else the list's own `menu(for:)` (so the
    /// App's provider builds it).
    public func debugMenu(atWindowPoint windowPoint: CGPoint) -> NSMenu? {
        let list = sidebarView.list
        guard let window = list.window else { return nil }
        let height = window.contentView?.bounds.height ?? window.frame.height
        let location = NSPoint(x: windowPoint.x, y: height - windowPoint.y)
        // The bands, then the document's sections drawn in the list: their items open their own menus.
        for region in sidebarView.bandRegions + list.blockRegions where !region.isHiddenOrHasHiddenAncestor {
            if let menu = region.debugItemMenu(atWindowPoint: location) { return menu }
        }
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location,
                                             modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
        return list.menu(for: event)
    }
}

extension SidebarRegionView {
    /// The context menu of the item under `location` (window coordinates), as its right-click builds it.
    func debugItemMenu(atWindowPoint location: NSPoint) -> NSMenu? {
        // A transient item (What's New) has no right-click menu.
        for (id, view) in itemViews where !id.isTransient && !view.isHiddenOrHasHiddenAncestor && view.window != nil {
            if view.bounds.contains(view.convert(location, from: nil)) { return contextMenuProvider?(.layoutItem(id)) }
        }
        return nil
    }
}

extension SidebarContainerView {
    /// `debug.motion` `trace_*` (a `MotionFrameTrace` sampler): the sidebar's animated width and
    /// its presented one; nil for another view.
    public static func motionSample(_ view: NSView) -> [String: [Any]]? {
        guard let sidebar = view as? SidebarContainerView else { return nil }
        return ["sidebar": [Double(sidebar.frame.width), Double(sidebar.layer?.presentation()?.bounds.width ?? sidebar.frame.width)]]
    }
}
