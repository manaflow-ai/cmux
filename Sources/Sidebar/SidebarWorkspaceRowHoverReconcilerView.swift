import AppKit

@MainActor
final class SidebarWorkspaceRowHoverReconcilerView: NSView {
    var onPointerHoverChanged: ((Bool) -> Void)?

    /// AppKit lifecycle callbacks publish into this bounded stream. The
    /// consumer task is the only path allowed to call back into SwiftUI, so
    /// `updateTrackingAreas` and `viewDidMoveToWindow` always return before a
    /// row's `@State` can change.
    private let hoverEvents: AsyncStream<Bool>
    private let hoverContinuation: AsyncStream<Bool>.Continuation
    private var hoverEventsTask: Task<Void, Never>?
    private var trackingArea: NSTrackingArea?
    private var lastReportedHover: Bool?

    override init(frame frameRect: NSRect) {
        let (hoverEvents, hoverContinuation) = AsyncStream.makeStream(
            of: Bool.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.hoverEvents = hoverEvents
        self.hoverContinuation = hoverContinuation
        super.init(frame: frameRect)
        startHoverEventConsumption()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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

    func stopHoverEventConsumption() {
        onPointerHoverChanged = nil
        hoverEventsTask?.cancel()
        hoverEventsTask = nil
        hoverContinuation.finish()
    }

    private func reportPointerHovering(_ hovering: Bool, force: Bool = false) {
        guard force || lastReportedHover != hovering else { return }
        lastReportedHover = hovering
        hoverContinuation.yield(hovering)
    }

    private func startHoverEventConsumption() {
        let hoverEvents = self.hoverEvents
        hoverEventsTask = Task { @MainActor [weak self] in
            for await hovering in hoverEvents {
                guard let self, !Task.isCancelled else { return }
                self.onPointerHoverChanged?(hovering)
            }
        }
    }

    deinit {
        hoverEventsTask?.cancel()
        hoverContinuation.finish()
    }
}
