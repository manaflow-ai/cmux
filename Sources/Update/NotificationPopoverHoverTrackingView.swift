import AppKit

final class HoverTrackingNSView: NSView {
    var onChange: (Bool) -> Void
    private var trackingArea: NSTrackingArea?
    private var isInside: Bool = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Pass clicks through to the SwiftUI parent (which owns the tap gesture and accessibility
    // action). Tracking areas keep working because they're driven by window mouse-tracking,
    // not by hitTest.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area

        // Sync current pointer state in case the pointer is already inside when the tracking
        // area is (re)installed — happens on first popover open or after layout changes.
        // updateTrackingAreas runs on the main thread, so dispatch synchronously; deferring
        // creates a race where mouseExited can fire before the queued sync-onChange(true) runs,
        // leaving the row stuck in the hovered state.
        if let window, window.isVisible {
            let mouseInWindow = window.mouseLocationOutsideOfEventStream
            let mouseInView = convert(mouseInWindow, from: nil)
            let nowInside = bounds.contains(mouseInView)
            if nowInside != isInside {
                isInside = nowInside
                onChange(nowInside)
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if !isInside {
            isInside = true
            onChange(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if isInside {
            isInside = false
            onChange(false)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isInside {
            isInside = false
            onChange(false)
        }
    }
}
