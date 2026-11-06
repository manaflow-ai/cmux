public import AppKit
import CmuxNextDesign
public import CmuxNextSettings

/// The view around a page that runs the app's Go Back / Go Forward for it (the app's page tab
/// view, history.md 4.2b: the shown page's own history, then the location trail). Pages with none
/// (a sidebar page, a popup) get no swipe events.
@MainActor
public protocol PageHistoryHosting: NSView {
    /// Runs Go Back (true) or Go Forward (false), as the mouse buttons 4 and 5 do.
    var navigate: ((Bool) -> Void)? { get }
}

/// One trackpad scroll event as the page's swipe stream carries it (webviews/src/swipeNavigation
/// `SwipeEvent`): the NSEvent fields only, unjudged.
public nonisolated struct PageSwipeEvent: Equatable, Sendable {
    public var phase: String
    public var momentum: Bool
    public var dx: Double
    public var dy: Double
    public var inverted: Bool
    /// Milliseconds.
    public var time: Double

    /// Nil for a mouse wheel (no precise deltas, no phase) and for a phase the page has no name for.
    public init?(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, dx: Double, dy: Double, precise: Bool,
                 inverted: Bool, timestamp: TimeInterval) {
        guard precise else { return nil }
        momentum = !momentumPhase.isEmpty
        let source = momentum ? momentumPhase : phase
        if source.contains(.mayBegin) { self.phase = "mayBegin" }
        else if source.contains(.began) { self.phase = "began" }
        else if source.contains(.changed) { self.phase = "changed" }
        else if source.contains(.ended) { self.phase = "ended" }
        else if source.contains(.cancelled) { self.phase = "cancelled" }
        else { return nil }
        self.dx = dx
        self.dy = dy
        self.inverted = inverted
        time = timestamp * 1000
    }

    /// The fingers' gesture starting (a touch or `began`), not its momentum.
    public var starts: Bool { !momentum && (phase == "began" || phase == "mayBegin") }

    /// The envelope data, with the gesture's number and, on a start, where Back and Forward can go.
    public func json(gesture: Int, back: Bool? = nil, forward: Bool? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "g": .number(Double(gesture)), "phase": .string(phase), "momentum": .bool(momentum),
            "dx": .number(dx), "dy": .number(dy), "inverted": .bool(inverted), "time": .number(time),
        ]
        if let back { fields["back"] = .bool(back) }
        if let forward { fields["forward"] = .bool(forward) }
        return .object(fields)
    }
}

/// Forwards phase-aware trackpad scroll events over an app page to the page (two-finger Back /
/// Forward; the gesture, the indicator and the animation are the page's, webviews/src/swipeNavigation).
/// Plumbing only: it decides nothing about the gesture. One local monitor for the app sees each
/// scroll event before the page does and never consumes it. A gesture goes to the page under the
/// pointer at its start, and only when:
/// - the system's "Swipe between pages" is on (`NSEvent.isSwipeTrackingFromScrollEventsEnabled`);
/// - the page listens (``PageRouter/hasSwipeSubscriber``) and sits in a ``PageHistoryHosting`` view;
/// - the layout did not take the gesture (Command + scroll moves columns and rows:
///   `isScrollGestureTakenByEnclosingView`); a gesture it takes later is cancelled for the page.
/// A mouse wheel (no phase) is never forwarded. The page releases a gesture it declined or finished
/// (``PageNativeOp/swipeRelease``), so the rest of it, momentum included, is not sent. Trackpad
/// events arrive at most once per display frame, so each is sent as it comes, with no added frame.
@MainActor
public final class PageSwipeForwarder {
    /// Where Back and Forward can go now (the titlebar arrows' state).
    private let availability: @MainActor () -> (back: Bool, forward: Bool)
    private var monitor: Any?
    private weak var page: PageWebView?
    private var gesture = 0
    /// The page that last got an event, and when: only a page in a live swipe may run Back / Forward
    /// (its commit can arrive after it released the gesture).
    private weak var lastPage: PageWebView?
    private var lastForwardUptime: TimeInterval = 0

    /// Made once by the app's history service, which owns it and runs the Back / Forward it asks for.
    public init(availability: @escaping @MainActor () -> (back: Bool, forward: Bool)) {
        self.availability = availability
        // AppKit calls a local monitor on the main thread (this type's isolation), as CEFSwipeNavigation's.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.forward(event)
            return event
        }
    }

    /// Runs on every scroll event in the app: a phase check, then a hit test only at a gesture start.
    private func forward(_ event: NSEvent) {
        guard let swipe = PageSwipeEvent(phase: event.phase, momentumPhase: event.momentumPhase,
                                         dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                                         precise: event.hasPreciseScrollingDeltas,
                                         inverted: event.isDirectionInvertedFromDevice, timestamp: event.timestamp) else { return }
        if swipe.starts {
            page = NSEvent.isSwipeTrackingFromScrollEventsEnabled ? pageView(under: event) : nil
            gesture += 1
        }
        guard let page else { return }
        if !swipe.momentum, page.isScrollGestureTakenByEnclosingView {
            var cancelled = swipe
            cancelled.phase = "cancelled"
            page.router.publishSwipe(cancelled.json(gesture: gesture))
            self.page = nil
            return
        }
        lastPage = page
        lastForwardUptime = ProcessInfo.processInfo.systemUptime
        let open = swipe.starts ? availability() : nil
        page.router.publishSwipe(swipe.json(gesture: gesture, back: open?.back, forward: open?.forward))
    }

    /// The page view under the event that takes swipes, binding its router's swipe ops on first use.
    private func pageView(under event: NSEvent) -> PageWebView? {
        guard let window = event.window else { return nil }
        // A Chromium page draws in a child window over its pane: hit-test the pane's own window.
        let host = window.parent ?? window
        guard let content = host.contentView else { return nil }
        let point = host.convertPoint(fromScreen: window.convertPoint(toScreen: event.locationInWindow))
        var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        while let current = view, !(current is PageWebView) { view = current.superview }
        guard let page = view as? PageWebView, page.router.hasSwipeSubscriber, Self.historyHost(of: page) != nil else { return nil }
        bind(page.router, to: page)
        return page
    }

    private static func historyHost(of page: PageWebView) -> (any PageHistoryHosting)? {
        var view = page.superview
        while let current = view {
            if let host = current as? any PageHistoryHosting { return host }
            view = current.superview
        }
        return nil
    }

    private func bind(_ router: PageRouter, to page: PageWebView) {
        guard router.historyNavigate == nil else { return }
        router.historyNavigate = { [weak self, weak page] back in
            // Only the page in a live swipe, within a moment of its last event, may navigate.
            guard let self, let page, lastPage === page, ProcessInfo.processInfo.systemUptime - lastForwardUptime < 2,
                  let navigate = Self.historyHost(of: page)?.navigate else { return false }
            navigate(back)
            return true
        }
        router.swipeRelease = { [weak self, weak page] gesture in
            guard let self, self.page === page, self.gesture == gesture else { return }
            self.page = nil
        }
    }
}
