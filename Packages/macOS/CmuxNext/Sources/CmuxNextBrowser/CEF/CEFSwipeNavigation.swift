import AppKit
import CmuxNextDesign
import CmuxNextInput
import CmuxNextInputCore

/// A two-finger horizontal swipe over a Chromium page goes Back or Forward, as in Safari and
/// Chrome (plans/cmux-next/history.md 4.2). A scroll intercept on the app's input tap sees each
/// scroll event over a page before Chromium does. `BrowserSwipeGesture` decides from the page's own answer
/// (`BrowserSwipeProbe`) whether the gesture is a swipe. The page keeps every gesture it would
/// scroll, and every gesture a script takes. Once the gesture is a swipe, `trackSwipeEvent`
/// follows the fingers and the indicator (`BrowserSwipeIndicator`) follows its amount. Letting
/// go past AppKit's threshold navigates. With no page that way, the swipe rubber-bands and
/// nothing happens.
///
/// It runs only while the system's "Swipe between pages" is on
/// (`NSEvent.isSwipeTrackingFromScrollEventsEnabled`) and Debug Settings
/// `browser.swipeNavigation` is on (the default). A gesture the layout took (Command + scroll
/// moves the columns and rows, decided once at the gesture's first event) is never a swipe: the
/// page's host view asks the layout around it (`isScrollGestureTakenByEnclosingView`, the one
/// owner decision) instead of testing the modifier keys here. A gesture the layout passes to the
/// page swipes like any other, as a WebKit page does with the same gesture.
///
/// The intercept runs only while a gesture over a page is under way or the pointer is in a page
/// window (``isListening(gestureOver:lastPointer:)``, two field reads): a scroll anywhere else in the
/// app costs no target search. Chrome likewise starts its history swipe from the scroll events its
/// page view receives (`chrome/browser/renderer_host/chrome_render_widget_host_view_mac_history_swiper.mm`),
/// not from every scroll of the app.
///
/// Host mode: a hosted page has no page window, so its ``ChromiumHostPageView`` hands each scroll here
/// first (``handleHosted(_:tab:page:)``), as Chrome's page view hands its scrolls to its history
/// swiper. When the host acks each wheel (``CEFHostStart/acksWheels``), the
/// gesture decides from Chromium's acks of its own wheels (WHEEL_ACK, ``wheelAcked(_:browser:)``):
/// no probe, so a gesture sends the host no control request. A host without acks is probed as in process.
@MainActor
final class CEFSwipeNavigation {
    /// The Chromium page under a scroll: its tab, the pane's host view and the point in it.
    struct Target {
        var tab: CEFTab
        var host: CEFHostView
        /// In the host view (not flipped).
        var point: CGPoint
    }

    /// Whether a gesture may swipe now: the setting and the system's swipe-between-pages preference.
    private let enabled: () -> Bool
    /// The page under a gesture's first scroll (`target(of:in:)` of the runtime; a test's fixed answer).
    private let locate: (NSEvent) -> Target?
    /// Whether the attached Chromium Host acks each wheel of a hosted page (read at a hosted gesture's start).
    private let acksWheels: () -> Bool
    private var subscription: InputSubscription?
    /// The tap `subscription` hears.
    private weak var input: InputEventTap?
    private(set) var gesture = BrowserSwipeGesture()
    private let pageProbe = BrowserSwipeProbe()
    /// The page the current gesture began over.
    private weak var tab: CEFTab?
    private weak var hostView: CEFHostView?
    /// Where the gesture began, in the host view (not flipped).
    private var point: CGPoint = .zero
    private var indicator: BrowserSwipeIndicator?
    /// The tracked swipe already navigated (AppKit may report its end more than once).
    private var navigated = false
    /// The current gesture came through a hosted page view (``handleHosted(_:tab:page:)``), not the intercept.
    private var hosted = false
    /// The browser whose WHEEL_ACKs the current gesture decides from; nil when it probes.
    private var ackBrowser: Int32?
    /// The first input seq of the current gesture's wheels: acks of earlier wheels are not its own.
    private var ackFloor: UInt32 = 0
    /// What gestures asked of their pages, for `debug.cef` (``CEFEngine/swipeStats``).
    private(set) var stats = CEFSwipeStats()

    /// Swipes over `runtime`'s shown pages, while the setting and the system preference allow them.
    convenience init(runtime: CEFRuntime) {
        self.init(enabled: { NavigationTunables.swipeNavigation.value && NSEvent.isSwipeTrackingFromScrollEventsEnabled },
                  locate: { [weak runtime] event in runtime.flatMap { CEFSwipeNavigation.target(of: event, in: $0) } },
                  acksWheels: { [weak runtime] in runtime?.hostStart?.acksWheels == true })
    }

    /// Swipes that ask `enabled` at each gesture's start and find its page with `locate`; a hosted page's
    /// gesture decides from wheel acks while `acksWheels` says the host sends them.
    init(enabled: @escaping () -> Bool, locate: @escaping (NSEvent) -> Target?, acksWheels: @escaping () -> Bool = { false }) {
        self.enabled = enabled
        self.locate = locate
        self.acksWheels = acksWheels
    }

    /// Starts hearing scrolls from `input`, the app's input tap. A later call with another tap moves
    /// the subscription to it; one with the same tap does nothing.
    func start(input: InputEventTap) {
        guard subscription == nil || self.input !== input else { return }
        self.input = input
        subscription = input.subscribe(class: .scroll, phase: .intercept(order: .standard),
                                       while: { [weak self, weak input] in
                                           CEFSwipeNavigation.isListening(gestureOver: self?.isFollowingInterceptedGesture == true,
                                                                          lastPointer: input?.lastPointer)
                                       }) { [weak self] event in
            self?.handle(event) ?? .pass
        }
    }

    /// Whether scrolls are heard now.
    var isStarted: Bool { subscription != nil }

    /// Whether a gesture that began over a page is under way (its scrolls are heard in any window).
    var isFollowingGesture: Bool { tab != nil }

    /// A gesture the intercept began is under way (a hosted page view's gesture comes through the view).
    private var isFollowingInterceptedGesture: Bool { tab != nil && !hosted }

    /// Whether the intercept handles the scroll the tap is delivering: a gesture that began over a
    /// page goes on (its events follow the fingers out of the page), and a new one can begin only in
    /// a Chromium page window, a child window over its cmux window (`lastPointer`, the event being
    /// delivered: its window is not its owner window). `CEFLinkClicks.browser` finds no page in any
    /// other window, so nothing that could swipe is skipped.
    nonisolated static func isListening(gestureOver: Bool, lastPointer: InputEventRecord?) -> Bool {
        if gestureOver { return true }
        guard let pointer = lastPointer, pointer.type == .scrollWheel else { return false }
        return pointer.windowNumber > 0 && pointer.windowNumber != pointer.ownerWindowNumber
    }

    func handle(_ event: NSEvent) -> InputEventTap.InterceptResult {
        // Momentum after a gesture never starts a swipe; a mouse wheel has no phases.
        guard event.momentumPhase.isEmpty, let phase = Self.scrollPhase(event.phase) else { return .pass }
        if phase == .began {
            guard enabled(), let target = locate(event) else {
                gesture.cancel()
                tab = nil
                return .pass
            }
            begin(target, hosted: false)
        } else if !isFollowingInterceptedGesture {
            return .pass
        }
        return step(event, phase)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// A scroll the hosted page view `page` of `tab` received, before it goes to the host; true when the swipe
    /// took it (``ChromiumHostPageView/wheelGesture``). The gesture decides from the host's WHEEL_ACKs of the
    /// wheels the view sends from its first one on, while the host sends them; else it probes the page.
    func handleHosted(_ event: NSEvent, tab: CEFTab, page: ChromiumHostPageView) -> Bool {
        guard event.momentumPhase.isEmpty, let phase = Self.scrollPhase(event.phase) else { return false }
        if phase == .began {
            let host = tab.host.hostView
            guard enabled(), host.window != nil else {
                gesture.cancel()
                self.tab = nil
                return false
            }
            begin(Target(tab: tab, host: host, point: host.convert(event.locationInWindow, from: nil)), hosted: true)
            if acksWheels(), let browser = tab.browserID {
                ackBrowser = browser
                ackFloor = page.lastWheelSeq &+ 1
            }
        } else if !hosted || self.tab !== tab {
            return false
        }
        return step(event, phase) == .consume
    }
    #endif

    /// The host's WHEEL_ACK of a wheel `browser`'s page view sent: the current gesture decides from it when it
    /// is that page's and the wheel is one of its own.
    func wheelAcked(_ ack: BrowserWheelAck, browser: Int32) {
        guard let ackBrowser, browser == ackBrowser, Int32(bitPattern: ack.seq &- ackFloor) >= 0 else { return }
        stats.acks += 1
        gesture.wheelAcked(ack)
    }

    /// A gesture's first scroll over `target`'s page.
    private func begin(_ target: Target, hosted: Bool) {
        tab = target.tab
        hostView = target.host
        point = target.point
        self.hosted = hosted
        ackBrowser = nil
        stats.gestures += 1
    }

    /// One scroll of the gesture under way.
    private func step(_ event: NSEvent, _ phase: BrowserSwipeGesture.ScrollPhase) -> InputEventTap.InterceptResult {
        // Asked on began and moving events (`BrowserSwipeGesture.scroll`): a superview walk, no allocation.
        // On began it is true when the layout decided at the touch, so a Command gesture never probes the page.
        let takenByLayout = (phase == .began || phase == .changed) && hostView?.isScrollGestureTakenByEnclosingView == true
        let step = gesture.scroll(phase, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, takenByLayout: takenByLayout,
                                  pageAcks: ackBrowser != nil)
        // The gesture is over: the intercept goes back to hearing only page windows (a running swipe
        // keeps its own tab).
        if phase == .ended { tab = nil }
        switch step {
        case .none:
            return .pass
        case .probe:
            probe()
            return .pass
        case .track(let direction):
            return track(event, direction: direction) ? .consume : .pass
        }
    }

    private static func scrollPhase(_ phase: NSEvent.Phase) -> BrowserSwipeGesture.ScrollPhase? {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) || phase.contains(.cancelled) { return .ended }
        return nil
    }

    /// The Chromium page of `runtime` under the event: its tab, the pane's host view and the point in it.
    private static func target(of event: NSEvent, in runtime: CEFRuntime) -> Target? {
        guard let window = event.window else { return nil }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        let targets = runtime.windowRequests.clickTargets()
        guard let browser = CEFLinkClicks.browser(clickedIn: ObjectIdentifier(window), parent: window.parent.map(ObjectIdentifier.init),
                                                  at: screenPoint, targets: targets),
              let tab = runtime.tabsByBrowser[browser],
              let host = runtime.hosts.values.first(where: { $0.visibleTab === tab })?.hostView,
              let hostWindow = host.window else { return nil }
        let point = host.convert(hostWindow.convertPoint(fromScreen: screenPoint), from: nil)
        return Target(tab: tab, host: host, point: point)
    }

    private func probe() {
        guard let tab, let hostView else { return }
        stats.probes += 1
        let zoom = max(CGFloat(tab.state.zoom), 0.25)
        let script = pageProbe.script(x: point.x / zoom, y: (hostView.bounds.height - point.y) / zoom)
        let generation = gesture.generation
        let pageProbe = pageProbe
        Task { @MainActor [weak self, weak tab] in
            let value = try? await tab?.evaluate(script, world: .page, gesture: .cmux)
            self?.gesture.probeAnswered(value.flatMap(pageProbe.edges), generation: generation)
        }
    }

    /// Starts AppKit's swipe tracking with `event`; false when it could not start.
    private func track(_ event: NSEvent, direction: BrowserSwipeDirection) -> Bool {
        guard let tab, let hostView else {
            gesture.cancel()
            return false
        }
        let canBack = tab.state.canGoBack
        let canForward = tab.state.canGoForward
        let available = direction == .back ? canBack : canForward
        let indicator = BrowserSwipeIndicator(page: hostView, direction: direction, available: available)
        self.indicator?.dismiss()
        self.indicator = indicator
        navigated = false
        stats.swipes += 1
        CEFSwipeTracking { [weak self, weak tab] amount, phase, isComplete in
            // A later swipe replaced this one: its pill goes, and never comes back.
            guard let self, self.indicator === indicator else {
                indicator.dismiss()
                return
            }
            indicator.update(amount: amount)
            if phase == .ended, !self.navigated, let tab {
                self.navigated = true
                Self.navigate(tab, direction: direction, amount: amount)
            }
            if isComplete {
                indicator.dismiss()
                self.indicator = nil
                self.gesture.swipeFinished()
            }
        }.start(with: event, canBack: canBack, canForward: canForward)
        return true
    }

    /// Letting go past the threshold: navigates when the page has an entry that way and the
    /// fingers still point there.
    private static func navigate(_ tab: CEFTab, direction: BrowserSwipeDirection, amount: CGFloat) {
        guard amount != 0, BrowserSwipeDirection(deltaX: amount) == direction else { return }
        switch direction {
        case .back where tab.state.canGoBack: tab.goBack()
        case .forward where tab.state.canGoForward: tab.goForward()
        default: break
        }
    }
}

/// What swipe gestures asked of their pages since launch (`debug.cef` `swipe`, chromium-host-bench.py's swipe
/// row): a gesture over a hosted page whose host acks wheels counts acks and no probes.
public nonisolated struct CEFSwipeStats: Equatable, Sendable {
    /// Gestures that began over a page.
    public var gestures = 0
    /// Page probes sent (a script run in the page: a control request in host mode).
    public var probes = 0
    /// WHEEL_ACKs of gestures' own wheels.
    public var acks = 0
    /// Swipes AppKit tracked.
    public var swipes = 0
    /// The attached Chromium Host acks each wheel of a hosted page (false in process).
    public var hostAcksWheels = false
}

extension CEFEngine {
    /// Swipe gestures over Chromium pages since launch.
    public var swipeStats: CEFSwipeStats {
        var stats = CEFRuntime.shared.swipeNavigation.stats
        stats.hostAcksWheels = CEFRuntime.shared.hostStart?.acksWheels == true
        return stats
    }
}
