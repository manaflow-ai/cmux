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

    // Reports are deduplicated against the last reported value: AppKit runs
    // updateTrackingAreas() for every visible row on every scroll movement,
    // and an unconditional report there is a SwiftUI state write per row per
    // scroll tick (the #7482 sidebar hang class). `repairing:` carries the
    // SwiftUI-tracked hover state; a report is forced only when that state
    // disagrees with pointer geometry, which is the row-reuse repair the
    // force previously existed for (#7539).
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
