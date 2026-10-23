import AppKit
import CmuxNextCompat

/// Tells a ``ThinScroller`` where the pointer is over its scroll view, so the knob shows and widens
/// as the pointer nears the trailing edge, and when the user scrolls the view (AppKit's live scroll
/// notification), so the knob shows then, as macOS overlay scrollers do. One tracking area on the
/// scroll view, pointer events only: nothing runs on a key press.
@MainActor
final class ThinScrollerProximity: NSResponder {
    private weak var scroller: ThinScroller?
    private weak var host: NSView?
    private var area: NSTrackingArea?
    /// AppKit's live scroll notification for `host`; stops when released (``detach()`` or this object's release).
    private var liveScroll: MainActorObservation?

    init(scroller: ThinScroller, host: NSView) {
        self.scroller = scroller
        self.host = host
        super.init()
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        host.addTrackingArea(area)
        self.area = area
        // queue: .main runs inline for AppKit's post on main, in the scroll's own turn.
        liveScroll = MainActorObservation(NSScrollView.didLiveScrollNotification, object: host) { [weak scroller] in
            if let scroller, scroller.showsOnScroll { scroller.flash() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Removes the tracking area (the scroller is leaving its scroll view).
    func detach() {
        if let area { host?.removeTrackingArea(area) }
        area = nil
        liveScroll = nil
    }

    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { scroller?.pointerMoved(to: nil) }

    private func report(_ event: NSEvent) {
        guard let host, let scroller, scroller.superview === host else { return }
        scroller.pointerMoved(to: host.convert(event.locationInWindow, from: nil))
    }
}
