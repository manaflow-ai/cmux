public import AppKit

extension SidebarViewComponents {
    // MARK: An item dragged in from elsewhere in the app (the Chief from Home), driven by the App

    /// Call on every pointer move of an app-driven item drag. True while `screenPoint` is over the sidebar: its
    /// list shows the drop outline and its chrome is revealed; false (outside, or hidden) clears them.
    public func itemDragUpdate(screenPoint: CGPoint) -> Bool {
        guard let window, model.presentation != .hidden, !isHiddenOrHasHiddenAncestor,
              bounds.contains(convert(window.convertPoint(fromScreen: screenPoint), from: nil)) else {
            itemDragExited()
            return false
        }
        // Tracking areas do not fire during an app-driven drag, as for a tab drag.
        setChromeRevealed(true)
        showDropOutline(list.convert(list.visibleRect, to: nil), refused: false)
        return true
    }

    /// The item drag left the sidebar, was released or was cancelled.
    public func itemDragExited() { tabDragExited() }
}
