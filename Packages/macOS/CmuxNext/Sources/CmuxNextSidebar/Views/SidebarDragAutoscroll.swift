import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// Edge autoscroll while a row or an external tab is dragged over the
/// sidebar: ticks on the window's FrameScheduler only while the pointer is
/// in an edge zone, and re-runs the drag at the new scroll position.
@MainActor
final class SidebarDragAutoscroll {
    unowned let list: SidebarListView
    /// Frames from the window's FrameScheduler, active only in an edge zone.
    lazy var client = FrameClient(owner: "Sidebar.autoscroll", view: list) { [weak self] tick in
        self?.tick(tick) ?? false
    }

    init(list: SidebarListView) {
        self.list = list
    }

    /// Scroll velocity for a drag at `windowPoint` (zero outside the edge zones).
    func velocity(windowPoint: NSPoint) -> CGFloat {
        guard let clip = list.enclosingScrollView?.contentView else { return 0 }
        let point = clip.convert(windowPoint, from: nil)
        let b = clip.bounds
        // Up to ~25 rows per second at the very edge.
        return SidebarAutoscroll.velocity(pointY: point.y, visibleMinY: b.minY, visibleMaxY: b.maxY,
                                          zone: SidebarStyle.autoscrollZone, maxSpeed: Metrics.sidebarRowHeight * 25)
    }

    /// Runs only while the pointer is in an edge zone.
    func update(windowPoint: NSPoint) {
        if velocity(windowPoint: windowPoint) != 0 { client.activate() } else { client.deactivate() }
    }

    func stop() {
        client.deactivate()
    }

    /// One autoscroll frame; false once there is nothing to scroll.
    private func tick(_ tick: FrameTick) -> Bool {
        guard let windowPoint = list.drag?.lastWindowPoint ?? list.external?.windowPoint,
              let scrollView = list.enclosingScrollView else { return false }
        let velocity = velocity(windowPoint: windowPoint)
        guard velocity != 0 else { return false }
        let clip = scrollView.contentView
        let b = clip.bounds
        let dt = tick.elapsed
        let maxY = max(0, list.frame.height - b.height)
        let y = min(max(b.minY + velocity * dt, 0), maxY)
        // At the content edge there is nothing to scroll: stop until the
        // pointer moves again.
        guard y != b.minY else { return false }
        clip.scroll(to: NSPoint(x: b.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
        if list.drag != nil {
            list.updateDrag(windowPoint: windowPoint)
        } else if let external = list.external {
            _ = list.externalDragMoved(windowPoint: windowPoint, sourceMachine: external.sourceMachine)
        }
        return true
    }
}
