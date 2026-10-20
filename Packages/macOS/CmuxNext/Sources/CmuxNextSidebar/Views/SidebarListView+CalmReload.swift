import AppKit

extension SidebarListView {
    /// The window's pointer is inside the list's visible part, with the list on screen in the active app
    /// (a pointer resting over a background app's window is not the user reading this list).
    var pointerIsOverVisibleRows: Bool {
        guard NSApp?.isActive == true, let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return false }
        return visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}
