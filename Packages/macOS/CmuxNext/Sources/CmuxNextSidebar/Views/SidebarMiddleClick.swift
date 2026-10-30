import AppKit

/// A left press on a sidebar row (`SidebarListView.Press`): the row, where
/// it went down, a click deferred to mouse-up, and whether it was cancelled.
struct SidebarPress {
    var key: SidebarRowKey
    var point: NSPoint
    var deferredClick: WorkspaceID?
    /// A plain press on a workspace row with `sidebar.multiView` on: it navigates only if the button comes up on
    /// the same row without a drag.
    var clickOnRelease: WorkspaceID?
    /// A plain press that switched on mouse-down (the default, `sidebar.multiView` off): what was shown and
    /// selected before it, put back if the press becomes a drag.
    var switchedOnPress: (shown: WorkspaceID?, selection: Set<WorkspaceID>)?
    /// A plain press on the shown workspace's row while it lists tabs: the release on that row without a drag
    /// folds or opens them, as a click on a Chrome tab group's header does (`SidebarListView.foldTabs`).
    var foldsTabs: WorkspaceID?
    var cancelled = false
    /// An item row that switched on mouse-down (`LayoutItemRef.activatesOnPress`): its release does not run it again.
    var activatedOnPress = false

    /// How far a press moves before it drags (Leo 2026-10-20: a plain click must never start a drag). A click's
    /// jitter on a trackpad reaches 4-5 pt; at the old 4 pt (`Metrics.space2`) such clicks lifted the row, or a
    /// group header with all its members. Points, not a density token: it is about the hand, not the layout.
    /// Debug Settings `sidebar.drag.threshold` (default 6).
    static var dragThreshold: CGFloat { SidebarTunables.dragThreshold.value }

    /// The pointer at `point` has moved from `start` far enough to start a drag.
    static func movedPastThreshold(from start: NSPoint, to point: NSPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) >= dragThreshold
    }
}

/// MIDDLE-CLICK-CLOSES-WORKSPACE: a middle click on a sidebar workspace row
/// closes that workspace through the row x's intent (`.close`, so the same
/// confirmation and the shared close path); on a tab listed beneath it, that
/// tab alone (`.closeTab`, Close Tab's path, as the tab strip's middle-click;
/// Leo 2026-10-27: "we need to be able to middle-click ... Like just closing
/// tabs fundamentally"); on a group or section row it does nothing. Down and
/// up must land on the same row.
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
        pressKey = list.clickHit(at: point)?.key
    }

    /// A middle press came up at `point` (list coordinates).
    func pressUp(at point: NSPoint, in list: SidebarListView) {
        defer { pressKey = nil }
        guard let key = list.clickHit(at: point)?.key, key == pressKey else { return }
        switch key {
        case let .workspace(id) where !list.model.isPlaceholder(id):
            list.model.send(.close([id]))
        case let .tab(workspace, tab):
            list.model.send(.closeTab(workspace: workspace, tab: tab))
        default:
            break
        }
    }
}
