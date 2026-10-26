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
@MainActor
final class CEFSwipeNavigation {
    private weak var runtime: CEFRuntime?
    private var subscription: InputSubscription?
    private var gesture = BrowserSwipeGesture()
    private let pageProbe = BrowserSwipeProbe()
    /// The page the current gesture began over.
    private weak var tab: CEFTab?
    private weak var hostView: CEFHostView?
    /// Where the gesture began, in the host view (not flipped).
    private var point: CGPoint = .zero
    private var indicator: BrowserSwipeIndicator?
    /// The tracked swipe already navigated (AppKit may report its end more than once).
    private var navigated = false

    init(runtime: CEFRuntime) {
        self.runtime = runtime
    }

    /// Starts hearing scrolls from `input`, the app's input tap.
    func start(input: InputEventTap) {
        guard subscription == nil else { return }
        subscription = input.subscribe(class: .scroll, phase: .intercept(order: .standard),
                                       while: { [weak self, weak input] in
                                           CEFSwipeNavigation.isListening(gestureOver: self?.tab != nil, lastPointer: input?.lastPointer)
                                       }) { [weak self] event in
            self?.handle(event) ?? .pass
        }
    }

    /// Whether scrolls are heard now.
    var isStarted: Bool { subscription != nil }

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
            guard NavigationTunables.swipeNavigation.value, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                  let target = target(of: event) else {
                gesture.cancel()
                tab = nil
                return .pass
            }
            tab = target.tab
            hostView = target.host
            point = target.point
        } else if tab == nil {
            return .pass
        }
        // Asked on began and moving events (`BrowserSwipeGesture.scroll`): a superview walk, no allocation.
        // On began it is true when the layout decided at the touch, so a Command gesture never probes the page.
        let takenByLayout = (phase == .began || phase == .changed) && hostView?.isScrollGestureTakenByEnclosingView == true
        let step = gesture.scroll(phase, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, takenByLayout: takenByLayout)
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

    /// The Chromium page under the event: its tab, the pane's host view and the point in it.
    private func target(of event: NSEvent) -> (tab: CEFTab, host: CEFHostView, point: CGPoint)? {
        guard let runtime, let window = event.window else { return nil }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        let targets = runtime.windowRequests.clickTargets()
        guard let browser = CEFLinkClicks.browser(clickedIn: ObjectIdentifier(window), parent: window.parent.map(ObjectIdentifier.init),
                                                  at: screenPoint, targets: targets),
              let tab = runtime.tabsByBrowser[browser],
              let host = runtime.hosts.values.first(where: { $0.visibleTab === tab })?.hostView,
              let hostWindow = host.window else { return nil }
        let point = host.convert(hostWindow.convertPoint(fromScreen: screenPoint), from: nil)
        return (tab: tab, host: host, point: point)
    }

    private func probe() {
        guard let tab, let hostView else { return }
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
        // A positive amount is Back (content dragged right). A side with no page clamps at 0, so
        // AppKit dampens past it: the rubber band.
        event.trackSwipeEvent(options: [.lockDirection], dampenAmountThresholdMin: canForward ? -1 : 0,
                              max: canBack ? 1 : 0) { [weak self, weak tab] amount, phase, isComplete, _ in
            MainActor.assumeIsolated { // main-proof: AppKit calls the swipe handler on the main thread, from event tracking
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
            }
        }
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
