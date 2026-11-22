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
}
