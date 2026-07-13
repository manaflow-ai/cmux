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

    func reconcileCurrentPointerLocation() {
        guard let window else {
            reportPointerHovering(false)
            return
        }
        reconcilePointerLocation(pointInView: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    func reconcilePointerLocation(pointInView: NSPoint) {
        reportPointerHovering(bounds.contains(pointInView), force: true)
    }

    private func reportPointerHovering(_ hovering: Bool, force: Bool = false) {
        guard force || lastReportedHover != hovering else { return }
        lastReportedHover = hovering
        onPointerHoverChanged?(hovering)
    }
}
