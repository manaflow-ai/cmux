import AppKit

/// A left press on a sidebar row (`SidebarListView.Press`): the row, where
/// it went down, a click deferred to mouse-up, and whether it was cancelled.
struct SidebarPress {
    var key: SidebarRowKey
    var point: NSPoint
    var deferredClick: WorkspaceID?
    var cancelled = false
}

/// MIDDLE-CLICK-CLOSES-WORKSPACE: a middle click on a sidebar workspace row
/// closes that workspace through the row x's intent (`.close`, so the same
/// confirmation and the shared close path); on a group, section or tab row
/// it does nothing. Down and up must land on the same row.
@MainActor
final class SidebarMiddleClick {
    /// The row the middle press went down on.
    private(set) var pressKey: SidebarRowKey?

    /// Handles a middle button press. False for another button.
    func down(_ event: NSEvent, in list: SidebarListView) -> Bool {
        guard event.buttonNumber == 2 else { return false }
        pressDown(at: list.convert(event.locationInWindow, from: nil), in: list)
        return true
    }

    /// Handles a middle button release. False for another button.
    func up(_ event: NSEvent, in list: SidebarListView) -> Bool {
        guard event.buttonNumber == 2 else { return false }
        pressUp(at: list.convert(event.locationInWindow, from: nil), in: list)
        return true
    }

    /// A middle press went down at `point` (list coordinates).
    func pressDown(at point: NSPoint, in list: SidebarListView) {
        list.hoverCards.dismiss(.click)
        pressKey = list.displayed.row(at: point.y)?.key
    }

    /// A middle press came up at `point` (list coordinates).
    func pressUp(at point: NSPoint, in list: SidebarListView) {
        defer { pressKey = nil }
        guard case let .workspace(id)? = list.displayed.row(at: point.y)?.key, pressKey == .workspace(id),
              !list.model.isPlaceholder(id) else { return }
        list.model.send(.close([id]))
    }
}
