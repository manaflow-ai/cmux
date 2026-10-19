import AppKit

struct TabStripPress {
    var id: TabID
    var start: CGPoint
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
}
