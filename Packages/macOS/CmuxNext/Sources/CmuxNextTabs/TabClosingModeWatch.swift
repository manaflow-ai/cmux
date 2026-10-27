import AppKit
import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups

// Chrome's mouse closing mode exit (tab_container_impl.cc L1418-1474, mouse_watcher.cc L26): after a
// mouse close the tabs keep their widths until the pointer has left the strip extended by
// `closingModeBelowPad` below and `closingModeTrailingPad` past its trailing edge, then
// `closingModeExitDelay` passes (a return cancels it), or the mouse is pressed outside the strip. Then
// the tabs resize on the close tween. The strip holds one watch while it is in closing mode.
//
// Outside the strip the watch hears, through the app's input tap and only until it ends: moves in the
// strip's window, presses in every window of the app (Chrome's MouseWatcher is an application monitor,
// views::EventMonitor::CreateApplicationMonitor), and other apps' moves and presses (`globalObserve`).
@MainActor final class TabClosingModeWatch {
    private weak var strip: TabStripView?
    /// Mouse closing mode ends `closingModeExitDelay` after the pointer leaves the strip's extended
    /// area; the subscriptions follow it outside the strip meanwhile. A `visible` deadline on the app's placer.
    private let exitTimer: MainDeadline
    private var exitMoves: InputSubscription?
    private var exitPresses: InputSubscription?
    private var exitOtherApps: InputSubscription?
    /// The extended closing-mode area while the pointer is outside the strip, on the window's content
    /// view (AppKit clips a tracking area to its view's bounds, and the pad lies outside the strip).
    private var trackingArea: NSTrackingArea?
    private weak var trackingHost: NSView?

    init(strip: TabStripView) {
        self.strip = strip
        exitTimer = MainDeadline(owner: "TabStrip.closingModeExit", workClass: .visible, scheduler: strip.deadlines)
    }

    /// The strip with Chrome's exit margins, in strip coordinates (flipped: y grows down).
    var area: CGRect {
        guard let strip else { return .zero }
        let g = strip.metrics.chrome, bounds = strip.bounds
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width + g.closingModeTrailingPad,
                      height: bounds.height + g.closingModeBelowPad)
    }

    /// The pointer left the strip in closing mode: follow it until it leaves the extended area.
    func pointerLeft() {
        if let strip, let window = strip.window { subscribe(strip.inputTap, window: window) }
        installTracking()
        pointerMoved(to: pointerInStrip)
    }

    private func subscribe(_ input: InputEventTap, window: NSWindow) {
        if exitMoves == nil {
            exitMoves = input.subscribe(class: .pointerMove, window: .window(window)) { [weak self] event in self?.pointerEvent(event) }
        }
        if exitPresses == nil {
            exitPresses = input.subscribe(class: .button) { [weak self] event in
                if Self.endsOnPress(event.type) { self?.pointerEvent(event) }
            }
        }
        // Moves and presses over other apps' windows or the desktop never pass this app's sendEvent.
        if exitOtherApps == nil {
            exitOtherApps = input.globalObserve([.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.pointerEvent(event, outsideApp: true)
            }
        }
    }

    /// Whether a button event of `type` is a press the watch acts on (a left or right press).
    static func endsOnPress(_ type: NSEvent.EventType) -> Bool {
        type == .leftMouseDown || type == .rightMouseDown
    }

    /// Whether the watch follows the pointer outside the strip now.
    var isFollowingPointer: Bool { exitMoves != nil || exitPresses != nil || exitOtherApps != nil }

    /// The strip's tracking areas changed: the extended rect follows while it is installed.
    func updateTracking() {
        if trackingArea != nil { installTracking() }
    }

    /// A tracking area on the extended rect: leaving it starts the exit delay even when the pointer
    /// goes into a view that does not track movement (no mouseMoved reaches the watch there). It lives
    /// on the window's content view, because AppKit clips a tracking area to its view's bounds and the
    /// pad (below and past the strip) lies outside the strip; the strip owns its events.
    private func installTracking() {
        removeTracking()
        guard let strip, let host = strip.window?.contentView else { return }
        let tracking = NSTrackingArea(rect: host.convert(area, from: strip), options: [.mouseEnteredAndExited, .activeAlways],
                                      owner: strip, userInfo: nil)
        host.addTrackingArea(tracking)
        trackingArea = tracking
        trackingHost = host
    }

    private func removeTracking() {
        if let trackingArea { trackingHost?.removeTrackingArea(trackingArea) }
        trackingArea = nil
        trackingHost = nil
    }

    /// Handles an enter or exit of the extended rect; false for any other tracking area's event. The
    /// pointer's own position decides (inside the pad cancels the exit, outside starts it).
    func trackingEvent(_ event: NSEvent, entered: Bool) -> Bool {
        guard let trackingArea, event.trackingArea === trackingArea else { return false }
        if entered { exitTimer.cancel() } else { pointerMoved(to: pointerInStrip) }
        return true
    }

    /// The pointer now, in strip coordinates, wherever it is on screen.
    private var pointerInStrip: CGPoint? {
        guard let strip else { return nil }
        return strip.window.map { strip.convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) }
    }

    private func pointerEvent(_ event: NSEvent, outsideApp: Bool = false) {
        guard let strip else { return }
        let point = pointerInStrip
        if event.type != .mouseMoved, outsideApp || event.window !== strip.window || !(point.map(strip.bounds.contains) ?? false) {
            exit()
        } else {
            pointerMoved(to: point)
        }
    }

    private func pointerMoved(to point: CGPoint?) {
        guard let strip, strip.closingModeWidth != nil, strip.drag == nil else { return end() }
        if let point, area.contains(point) {
            exitTimer.cancel()
        } else {
            let delay = strip.metrics.chrome.closingModeExitDelay
            exitTimer.scheduleIfIdle(after: .milliseconds(Int((delay * 1000).rounded()))) { [weak self] in
                self?.exit()
            }
        }
    }

    /// The pointer came back into the strip: closing mode stays.
    func pointerReturned() {
        exitTimer.cancel()
    }

    /// Ends closing mode: the tabs resize to the full strip on the close tween.
    func exit() {
        end()
        guard let strip, strip.closingModeWidth != nil else { return }
        strip.closingModeWidth = nil
        strip.relayout(animated: !strip.reduceMotion, token: .tabClose)
    }

    func end() {
        exitTimer.cancel()
        for subscription in [exitMoves, exitPresses, exitOtherApps] { subscription?.cancel() }
        exitMoves = nil
        exitPresses = nil
        exitOtherApps = nil
        removeTracking()
    }
}
