public import AppKit

/// A tab row (Show Tabs Under Workspaces) dragged past the drag distance:
/// the App's tab drag takes the tab from here, as one torn off its strip.
public struct SidebarTabRowDragHandoff {
    public var workspace: WorkspaceID
    public var tab: TabID
    /// The row's frame in screen coordinates.
    public var rowScreenFrame: CGRect
    /// Pointer offset from the row frame's origin (screen space, y up).
    public var grabOffset: CGPoint
    public var screenPoint: CGPoint
}

/// Offers a tab row past the drag distance to the App's tab drag, once per
/// press; the sidebar runs no drag of its own for a tab row.
@MainActor final class SidebarTabRowDrag {
    /// Returns true when the App took the tab; false (no drag can start,
    /// e.g. its workspace is not shown) leaves it.
    var offer: ((SidebarTabRowDragHandoff) -> Bool)?

    func dragged(_ workspace: WorkspaceID, _ tab: TabID, press: SidebarPress, event: NSEvent, in list: SidebarListView) {
        let point = list.convert(event.locationInWindow, from: nil)
        guard hypot(point.x - press.point.x, point.y - press.point.y) >= SidebarStyle.dragThreshold else { return }
        list.press?.cancelled = true
        guard let offer, let window = list.window, let row = list.displayed.row(for: .tab(workspace, tab)) else { return }
        let rowFrame = window.convertToScreen(list.convert(list.frame(for: row), to: nil))
        let pressed = window.convertPoint(toScreen: list.convert(press.point, to: nil))
        _ = offer(SidebarTabRowDragHandoff(
            workspace: workspace, tab: tab, rowScreenFrame: rowFrame,
            grabOffset: CGPoint(x: pressed.x - rowFrame.minX, y: pressed.y - rowFrame.minY),
            screenPoint: window.convertPoint(toScreen: event.locationInWindow)))
    }
}

extension SidebarListView {
    var onTabRowDrag: ((SidebarTabRowDragHandoff) -> Bool)? {
        get { tabRowDrag.offer }
        set { tabRowDrag.offer = newValue }
    }
}

extension SidebarContainerView {
    /// Offered each tab row drag (`SidebarTabRowDrag`).
    public var onTabRowDrag: ((SidebarTabRowDragHandoff) -> Bool)? {
        get { sidebarView.list.onTabRowDrag }
        set { sidebarView.list.onTabRowDrag = newValue }
    }
}
