import AppKit
import CmuxNextCompat
import CmuxNextInput
import CmuxNextWakeups

/// Tells a ``ThinScroller`` where the pointer is over its scroll view, so the knob shows and widens
/// as the pointer nears the trailing edge, and when the user scrolls the view (AppKit's live scroll
/// notification), so the knob shows then, as macOS overlay scrollers do. One tracking area on the
/// scroll view, pointer events only: nothing runs on a key press.
///
/// With its window's frames (``HoverFrameInputHosting``, feature `pointerFrameHover`, read when the
/// scroller joins the window) the moves report on the window's frame: the first of a frame interval in
/// its own turn, the rest once at the frame, at the latest point (``PointerFrameHover``). An enter
/// reports at once; an exit drops the waiting moves.
@MainActor
final class ThinScrollerProximity: NSResponder {
    private weak var scroller: ThinScroller?
    private weak var host: NSView?
    private var area: NSTrackingArea?
    private var liveScroll: MainActorObservation?
    private let notificationCenter: NotificationCenter
    /// The moves on the host window's coalescer.
    let frameInput: PointerFrameHover

    init(scroller: ThinScroller, host: NSView, notificationCenter: NotificationCenter) {
        self.scroller = scroller
        self.host = host
        self.notificationCenter = notificationCenter
        frameInput = PointerFrameHover(owner: "ThinScrollerProximity", view: host) { [weak scroller, weak host] point in
            guard let host, let scroller, scroller.superview === host else { return }
            scroller.pointerMoved(to: host.convert(point, from: nil))
        }
        super.init()
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        host.addTrackingArea(area)
        self.area = area
        // The scroll view's own notice (no window or app notice says it): delivered inline for AppKit's post on
        // main, in the scroll's own turn.
        liveScroll = MainActorObservation(NSScrollView.didLiveScrollNotification, object: host, center: notificationCenter) { [weak scroller] in
            if let scroller, scroller.showsOnScroll { scroller.flash() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Removes the tracking area (the scroller is leaving its scroll view).
    func detach() {
        frameInput.cancel()
        if let area { host?.removeTrackingArea(area) }
        area = nil
        liveScroll?.cancel()
        liveScroll = nil
    }

    override func mouseEntered(with event: NSEvent) {
        frameInput.flush()
        report(event)
    }

    /// The scroller joined `window` (or left every window): its moves wait on that window's frames.
    func windowChanged(_ window: NSWindow?) {
        frameInput.frames = (window as? HoverFrameInputHosting)?.hoverFrameInput
    }

    override func mouseMoved(with event: NSEvent) { frameInput.moved(event) }

    override func mouseExited(with event: NSEvent) {
        // Leaving the view settles the knob: the waiting moves would only widen it on the way out.
        frameInput.cancel()
        scroller?.pointerMoved(to: nil)
    }

    private func report(_ event: NSEvent) {
        guard let host, let scroller, scroller.superview === host else { return }
        scroller.pointerMoved(to: host.convert(event.locationInWindow, from: nil))
    }
}
