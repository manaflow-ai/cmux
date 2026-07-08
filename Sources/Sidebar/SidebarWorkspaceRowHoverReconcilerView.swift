import AppKit

final class SidebarWorkspaceRowHoverReconcilerView: NSView {
    var onPointerHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var lastReportedHover: Bool?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let nextTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
        reconcileCurrentPointerLocation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileCurrentPointerLocation()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func mouseEntered(with event: NSEvent) {
        reconcileCurrentPointerLocation()
    }

    override func mouseExited(with event: NSEvent) {
        reportPointerHovering(false)
    }

    func reconcileCurrentPointerLocation(repairing trackedPointerHovering: Bool? = nil) {
        guard let window else {
            reportPointerHovering(false, force: trackedPointerHovering == true)
            return
        }
        reconcilePointerLocation(
            pointInView: convert(window.mouseLocationOutsideOfEventStream, from: nil),
            repairing: trackedPointerHovering
        )
    }

    func reconcilePointerLocation(pointInView: NSPoint, repairing trackedPointerHovering: Bool? = nil) {
        let pointerHovering = bounds.contains(pointInView)
        reportPointerHovering(
            pointerHovering,
            force: trackedPointerHovering.map { $0 != pointerHovering } ?? false
        )
    }

    private func reportPointerHovering(_ hovering: Bool, force: Bool = false) {
        guard force || lastReportedHover != hovering else { return }
        lastReportedHover = hovering
        onPointerHoverChanged?(hovering)
    }
}
