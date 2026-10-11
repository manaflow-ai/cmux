#if DEBUG
public import AppKit

/// One group header's keyboard focus, for `debug.focus_ring`: whether its
/// view draws the ring now (nil while the header has no view) and where it is.
public struct SidebarDebugHeaderFocus: Sendable {
    public var group: String
    public var name: String
    /// The header view draws the keyboard focus ring (nil: no view realized).
    public var ringDrawn: Bool?
    /// The header in window points from the top-left (as `debug.mouse` takes them).
    public var windowFrame: CGRect
}

extension SidebarView {
    /// The workspace list view: the view that takes the sidebar's keys
    /// (`debug.view_key` view `sidebar.list`).
    public var debugKeyView: NSView { list }

    /// Keyboard focus in the list (debug): the focused group, whether the
    /// keyboard put it there (ring shown), and each group header's drawn ring.
    public func debugFocusRing() -> (focusedGroup: String?, ringShown: Bool, headers: [SidebarDebugHeaderFocus]) {
        let height = window?.contentView?.bounds.height ?? 0
        let headers = list.displayed.rows.compactMap { row -> SidebarDebugHeaderFocus? in
            guard case let .group(id) = row.key else { return nil }
            let inWindow = list.convert(list.frame(for: row), to: nil)
            return SidebarDebugHeaderFocus(
                group: id.description, name: list.groups[id]?.name ?? "",
                ringDrawn: (list.rowViews[row.key] as? GroupHeaderRowView)?.isKeyboardFocused,
                windowFrame: CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
            )
        }
        return (list.focusedGroup?.description, list.showsFocusRing, headers)
    }
}
#endif
