public import AppKit
import CmuxNextBrowserAutomation
public import CmuxNextPages
import Foundation
public import WebKit

/// Engine-level pointer input for one chat page, with no system pointer (``AgentChatDriveControl``,
/// `agent.chat.drive`): the page sees trusted events (`isTrusted`, real `:hover`, a real wheel that
/// scrolls), and nothing else in the app or the system does. Nothing is posted to the window, the
/// event queue or the window server; the person's pointer never moves, and no window is focused,
/// raised or ordered.
///
/// - WebKit: AppKit events handed to the web view itself (a move through WebKit's
///   `_simulateMouseMove:` when it has it, as the browser driver's `WebKitNativeInput` does, else
///   `mouseMoved(with:)`; a wheel through `scrollWheel(with:)`, routed by the page host's `PageWKWebView` as a
///   person's is). That view records only a real key or button as the person's gesture
///   (``PageWebView/lastUserEventUptime``), never a move or a wheel, so this input never counts as theirs.
/// - Chromium: DevTools `Input.dispatchMouseEvent` (`mouseMoved`, `mouseWheel`), as `debugHover` does.
///
/// Points are the page's viewport CSS pixels from its top-left, as `getBoundingClientRect` gives them.
/// The views are held weakly: input for a view that is gone does nothing, and a release there
/// reports ``ReleaseOutcome/gone``.
public struct AgentChatDriveInput {
    private enum Engine {
        case webKit(WKWebView)
        case chromium(PageWebView, any PageChromiumPage)
    }

    /// What one release did.
    public enum ReleaseOutcome: Sendable, Equatable {
        /// The pointer-leave went in: the page dropped the hover.
        case wentIn
        /// Nothing is left to hold a hover: the web view is gone, or the Chromium page closed or no
        /// longer shows the page (its target is gone).
        case gone
        /// Not sent, and the hover may still be held (a WebKit view out of every window keeps a stale
        /// `:hover`): try again, at the latest when the view is back in a window.
        case failed
    }

    private weak var webView: WKWebView?
    private weak var pageView: PageWebView?
    private weak var chromiumPage: (any PageChromiumPage)?

    /// Whether the page showed in Chromium (DevTools input and layout counters) rather than WebKit.
    public let isChromium: Bool

    /// WebKit's handling of the mouse events sent so far, at most the bound: true when WebKit answered,
    /// false when the bound passed first, nil when it can't be known (an unverified macOS, no SPI).
    /// Tests pass their own.
    var pendingMouseEvents: @MainActor (WKWebView, Duration) async -> Bool? = { await AgentChatDriveInput.afterPendingMouseEvents($0, bound: $1) }
    /// WebKit's next presentation update, at most the bound. Tests pass their own.
    var presentationUpdate: @MainActor (WKWebView, Duration) async -> Void = { await AgentChatDriveInput.afterPresentationUpdate($0, bound: $1) }

    /// Input for a bare WebKit view (the pane's own WebKit host; tests).
    public init(webView: WKWebView) {
        self.webView = webView
        isChromium = false
    }

    /// Input for a page on the shared page host, in whichever engine shows it now.
    public init(page: PageWebView) {
        pageView = page
        chromiumPage = page.chromiumPage
        isChromium = page.chromiumPage != nil
        if !isChromium { webView = page.webKitView }
    }

    /// The engine the input goes to now; nil when it is gone (the view released, or the Chromium page
    /// closed or replaced: the page view no longer shows it).
    private var engine: Engine? {
        guard isChromium else { return webView.map(Engine.webKit) }
        guard let pageView, let chromiumPage, pageView.chromiumPage === chromiumPage else { return nil }
        return .chromium(pageView, chromiumPage)
    }

    /// Moves the page's pointer to `css` and holds it there: the element under it is hovered until
    /// another move. False when no event could be made or sent (no window, the page is gone).
    public func move(to css: CGPoint) async -> Bool {
        guard css.x.isFinite, css.y.isFinite, let engine else { return false }
        switch engine {
        case .webKit(let webView):
            return Self.webKitMove(webView, viewPoint: Self.viewPoint(webView, css: css))
        case .chromium(_, let page):
            return await Self.devToolsMove(page, css: css)
        }
    }

    /// The longest a wheel tick waits for WebKit's presentation update, and then for its pending mouse
    /// events (a window that cannot present gives none), each cut to the run's time left (``bounded(_:before:now:)``).
    static let wheelWait = Duration.milliseconds(500)

    /// `bound`, cut to the time left before `deadline` (none: all of it); nil when no time is left.
    static func bounded(_ bound: Duration, before deadline: ContinuousClock.Instant?, now: ContinuousClock.Instant = .now) -> Duration? {
        guard let deadline else { return bound }
        let left = deadline - now
        return left > .zero ? min(bound, left) : nil
    }

    /// One wheel tick of `deltaY` CSS px at `css`, with the sign the page's `wheel` event reports
    /// (positive scrolls the content down). False when no event could be made or sent.
    /// With `deadline` (the run's end), the tick's waits for WebKit end by then, and a tick with no time
    /// left sends without them.
    public func wheel(at css: CGPoint, deltaY: Double, before deadline: ContinuousClock.Instant? = nil) async -> Bool {
        guard css.x.isFinite, css.y.isFinite, deltaY.isFinite, let engine else { return false }
        switch engine {
        case .webKit(let webView):
            // WebKit drops a wheel that reaches the page before its next presentation update, and coalesces
            // wheels still pending: each tick waits for both (as WebKitNativeInput.wheel does), so ticks a
            // frame or less apart each reach the page. Each wait is bounded by `wheelWait` and the time left.
            if let bound = Self.bounded(Self.wheelWait, before: deadline) { await presentationUpdate(webView, bound) }
            guard let window = webView.window,
                  let event = Self.wheelEvent(window: window, location: webView.convert(Self.viewPoint(webView, css: css), to: nil), deltaY: deltaY)
            else { return false }
            // The view's own override routes it (`PageWKWebView.scrollWheel(with:)`), as a person's wheel.
            webView.scrollWheel(with: event)
            if let bound = Self.bounded(Self.wheelWait, before: deadline) { _ = await pendingMouseEvents(webView, bound) }
            return true
        case .chromium(_, let page):
            return (try? await page.devTools("Input.dispatchMouseEvent", params: [
                "type": "mouseWheel", "x": Double(css.x), "y": Double(css.y), "deltaX": 0.0, "deltaY": deltaY,
                "button": "none", "buttons": 0, "modifiers": 0,
            ])) != nil
        }
    }

    /// Gives the hover back to the person's pointer: a move to where the real pointer is when it is
    /// over this page (and no other window covers it there), else to a point just outside the page,
    /// so the page drops the hover exactly as when the real pointer is elsewhere.
    public func release() async -> ReleaseOutcome {
        guard let engine else { return .gone }
        switch engine {
        case .webKit(let webView):
            // AppKit events need a window: a detached view keeps its hover until it is back in one.
            guard let window = webView.window else { return .failed }
            let pointer = Self.realPointer(in: webView, window: window)
            let outside = NSPoint(x: -1, y: webView.isFlipped ? -1 : webView.bounds.height + 1)
            guard Self.webKitMove(webView, viewPoint: pointer ?? outside) else { return .failed }
            // WebKit drops a move outside its visible rect while the view is first responder (the chat the
            // person types in), so the hover there ends the way the real pointer's leaving ends it: an exit.
            if pointer == nil, window.firstResponder === webView,
               let exit = NSEvent.enterExitEvent(with: .mouseExited, location: webView.convert(outside, to: nil), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                webView.mouseExited(with: exit)
            }
            // Done only once WebKit has handled it: a release reported while its move is still queued would
            // stop the retries with `:hover` still on, if that move then came late. Bounded as a tick's wait,
            // and a wait that ran out is not handled: the release tries again. Where WebKit can't say (nil),
            // the move was sent and counts.
            guard await pendingMouseEvents(webView, Self.wheelWait) != false else { return .failed }
            return .wentIn
        case .chromium(let view, let page):
            let zoom = max(view.pageZoom, 0.01)
            // The page view is flipped (top-left origin), as the page's viewport is.
            let css = view.window.flatMap { Self.realPointer(in: view, window: $0) }.map { CGPoint(x: $0.x / zoom, y: $0.y / zoom) }
            if await Self.devToolsMove(page, css: css ?? CGPoint(x: -1, y: -1)) { return .wentIn }
            // A page that closed while the move was on its way has no hover left.
            return self.engine == nil ? .gone : .failed
        }
    }

    /// Waits until the engine has handled the input sent so far, so a page read after it sees its
    /// effect: WebKit's next presentation update, then its pending mouse events (each bounded to
    /// `bound`, and cut to the time left before `deadline`: none left, no wait); Chromium handled each
    /// DevTools input before it answered.
    public func settle(bound: Duration = .seconds(1), before deadline: ContinuousClock.Instant? = nil) async { // timeout: only how long one settle waits for WebKit to answer; when it runs out the run goes on, and nothing the person does waits on it
        guard case .webKit(let webView)? = engine else { return }
        // A wheel that reaches a page before its next presentation update is dropped (WebKitNativeInput).
        if let bound = Self.bounded(bound, before: deadline) { await presentationUpdate(webView, bound) }
        if let bound = Self.bounded(bound, before: deadline) { _ = await pendingMouseEvents(webView, bound) }
    }

    // MARK: Chromium layout counters

    /// The counters ``engineCounters(since:)`` reports deltas of.
    public nonisolated static let counterNames = ["LayoutCount", "RecalcStyleCount", "LayoutDuration", "RecalcStyleDuration"]

    /// Chromium's layout and style counters now (`Performance.enable`, then `Performance.getMetrics`),
    /// the start of a span: nil on WebKit, which has none for the app, or when `Performance.enable`
    /// failed; empty when it went in but Chromium gave no metrics.
    public func startEngineCounters() async -> [String: Double]? {
        guard case .chromium(_, let page)? = engine else { return nil }
        guard (try? await page.devTools("Performance.enable", params: [:])) != nil else { return nil }
        return await Self.metrics(page) ?? [:]
    }

    /// How much each counter grew since `start` (Chromium's names; the durations in seconds), then
    /// `Performance.disable`, sent only when ``startEngineCounters()``'s enable went in (a non-nil
    /// `start`). Nil on WebKit, or when Chromium gave no metrics.
    public func engineCounters(since start: [String: Double]?) async -> [String: Double]? {
        guard case .chromium(_, let page)? = engine, let start else { return nil }
        let end = await Self.metrics(page)
        _ = try? await page.devTools("Performance.disable", params: [:])
        guard !start.isEmpty, let end else { return nil }
        var deltas: [String: Double] = [:]
        for name in Self.counterNames { if let to = end[name], let from = start[name] { deltas[name] = to - from } }
        return deltas
    }

    private static func metrics(_ page: any PageChromiumPage) async -> [String: Double]? {
        guard let json = try? await page.devTools("Performance.getMetrics", params: [:]),
              let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let metrics = object["metrics"] as? [[String: Any]] else { return nil }
        var values: [String: Double] = [:]
        for metric in metrics {
            if let name = metric["name"] as? String, counterNames.contains(name), let value = metric["value"] as? Double { values[name] = value }
        }
        return values
    }

    // MARK: Points and events

    /// CSS pixels (viewport top-left) to the web view's own coordinates: times its page zoom and
    /// magnification (a page's UI scale and chat zoom are its `pageZoom`), flipped when the view is not.
    static func viewPoint(_ webView: WKWebView, css: CGPoint) -> NSPoint {
        let scale = max(webView.pageZoom * webView.magnification, 0.01)
        let y = css.y * scale
        return NSPoint(x: css.x * scale, y: webView.isFlipped ? y : webView.bounds.height - y)
    }

    /// Where the person's real pointer is in `view`'s coordinates, when it is over the view's
    /// visible part and this window is the one under it there; nil otherwise.
    static func realPointer(in view: NSView, window: NSWindow) -> NSPoint? {
        let screen = NSEvent.mouseLocation
        guard isTopmost(window, at: screen) else { return nil }
        let point = view.convert(window.convertPoint(fromScreen: screen), from: nil)
        return view.visibleRect.contains(point) ? point : nil
    }

    /// Whether `window`, or one of its child windows (a Chromium page shows in its own child window
    /// over the host's), is the window on top at `screen` (global coordinates).
    static func isTopmost(_ window: NSWindow, at screen: NSPoint) -> Bool {
        let top = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
        return top == window.windowNumber || (window.childWindows ?? []).contains { $0.windowNumber == top }
    }

    private static func webKitMove(_ webView: WKWebView, viewPoint: NSPoint) -> Bool {
        guard let window = webView.window,
              let event = NSEvent.mouseEvent(with: .mouseMoved, location: webView.convert(viewPoint, to: nil), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return false }
        // A macOS WebKitPrivateCalls has not verified gets the public mouseMoved(with:) instead.
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let simulate = NSSelectorFromString("_simulateMouseMove:")
        if WebKitPrivateCalls().isVerified, webView.responds(to: simulate) { webView.perform(simulate, with: event) } else { webView.mouseMoved(with: event) }
        return true
    }

    private static func devToolsMove(_ page: any PageChromiumPage, css: CGPoint) async -> Bool {
        // DevTools input is in the viewport's CSS pixels; Chromium scales it by the zoom itself (debugHover).
        (try? await page.devTools("Input.dispatchMouseEvent", params: [
            "type": "mouseMoved", "x": Double(css.x), "y": Double(css.y), "button": "none", "buttons": 0, "modifiers": 0,
        ])) != nil
    }

    /// A one-wheel pixel scroll at `location` (window coordinates) that AppKit and WebKit read as a
    /// trackpad's, never posted: made from a Quartz event (`scrollWheelEvent2Source`) whose place is
    /// the window point's screen location (top-left origin), as `WebKitNativeInput` makes its wheel.
    private static func wheelEvent(window: NSWindow, location: NSPoint, deltaY: Double) -> NSEvent? {
        // Page deltas scroll content; wheel deltas are the finger direction.
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: Int32(clamping: Int(-deltaY.rounded())), wheel2: 0, wheel3: 0) else { return nil }
        // The Quartz location AppKit gives its own event at this window point.
        guard let place = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 0, pressure: 0)?.cgEvent?.location else { return nil }
        cg.location = place
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Without a window the event's location stays in screen space and WebKit hit-tests the wheel elsewhere.
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard var event = NSEvent(cgEvent: cg) else { return nil }
        // WebKit reads the wheel's place from `locationInWindow`, which AppKit derives from the Quartz
        // location; move it until it reads `location` (Quartz y grows down, Cocoa y up).
        for _ in 0..<3 where event.locationInWindow != location {
            let read = event.locationInWindow
            cg.location = CGPoint(x: cg.location.x + location.x - read.x, y: cg.location.y - (location.y - read.y))
            guard let moved = NSEvent(cgEvent: cg) else { return nil }
            event = moved
        }
        return event
    }

    /// WebKit's next presentation update, at most `bound` (``WebKitPrivateCalls``: its callback is bounded and
    /// resumes once, and a suspended page is skipped); at once on a macOS the private calls were not verified on.
    private static func afterPresentationUpdate(_ webView: WKWebView, bound: Duration) async {
        let calls = WebKitPrivateCalls(callbackBound: bound)
        guard calls.isVerified else { return }
        await calls.afterNextPresentationUpdate(webView)
    }

    /// WebKit's handling of the mouse events sent so far, at most `bound`, the same way: true when it
    /// answered, false when the bound passed first, nil on an unverified macOS or without the SPI.
    @discardableResult
    static func afterPendingMouseEvents(_ webView: WKWebView, bound: Duration) async -> Bool? {
        let calls = WebKitPrivateCalls(callbackBound: bound)
        guard calls.isVerified else { return nil }
        return await calls.afterPendingMouseEvents(webView)
    }
}
