import AppKit

struct TabStripPress {
    var id: TabID
    var start: CGPoint
    /// A plain press on one of several selected tabs: the release, if no drag began, selects that
    /// tab alone (Chrome keeps the selection for a drag until then).
    var collapsesSelection = false
}

struct TabStripDrag {
    var id: TabID
    var grabOffset: CGFloat
    var originalIndex: Int
    var currentIndex: Int
    var isPinned: Bool
    var lastPoint: CGPoint
    var originalGroup: TabGroupID?
    var targetGroup: TabGroupID?
    var grabY: CGFloat = 0 // press y in the clip; with grabOffset, the grabbed point the hand-off keeps
    /// Pointer x (content coordinates) at the last reorder: the next one waits until the pointer has
    /// moved the reorder threshold from here (Chrome's kHorizontalMoveThreshold, against jitter).
    var lastMoveX: CGFloat = 0
    /// Escape ended a multi-tab drag: the selection stays where it was.
    var cancelled = false
}
