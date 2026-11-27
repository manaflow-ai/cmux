import AppKit

/// Mouse-down state retained until a workspace row crosses the drag threshold.
struct SidebarWorkspacePendingDrag {
    let mouseDownEvent: NSEvent
    let startPoint: NSPoint
    let candidate: SidebarWorkspaceDragCandidate
}
