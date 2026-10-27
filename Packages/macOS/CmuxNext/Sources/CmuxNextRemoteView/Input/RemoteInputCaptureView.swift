package import AppKit
import CmuxNextDesign
import CmuxNextCompat
import CmuxNextInput
import CmuxNextWakeups
package import CmuxNextInputCore

/// The pane's input surface, over the video. It takes keyboard focus on
/// click; while it is first responder in control mode, keys, pointer,
/// buttons and scroll go to the host. Coordinates are flipped like stream
/// pixels. The local cursor stays the system arrow (control mode draws the
/// native cursor locally, RD6).
///
/// With ``pointerFrames`` (feature `pointerFrameRemoteInput`) moves, drags, mid-gesture scrolls and
/// wheel notches reach the host at most twice per display frame: a frame interval's first event at once, the rest
/// merged into one delivery at the window's frame (the latest point; scroll deltas summed per phase),
/// as Chromium delivers rAF-aligned input (`third_party/blink/renderer/platform/widget/input/
/// main_thread_event_queue.cc`). Buttons, keys and scroll phase edges flush what waits first
/// (`ShouldFlushQueue`), so the host sees every event in the order it came.
final class RemoteInputCaptureView: NSView, MouseButtonForwarding {
    let controller = RemoteInputController()
    /// The current image placement, from the video view.
    var geometry: () -> RemoteViewGeometry? = { nil }
    /// Called when focus or the mode changes so the pane can update chrome.
    var onFocusChange: ((Bool) -> Void)?
    /// A mouse button went down on the surface (before it is sent).
    var onMouseDown: (() -> Void)?
    var controlMode = false {
        didSet { updateActive() }
    }
    /// False: clicks and scrolls pass through to what is under the surface
    /// (a state card over the picture), never to the host.
    var acceptsPointer = true
    /// The windows' frame-aligned pointer input; nil sends every move and scroll at once.
    var pointerFrames: FrameInputCoalescers? {
        didSet { if pointerFrames !== oldValue { dropFramePointer() } }
    }
    /// This view's consumer of its window's coalescer, made on the first move in a window.
    private var framePointer: PointerFrameConsumer?

    private var isFirstResponder = false
    private var markedText = NSAttributedString()
    /// The key event being interpreted by the input method.
    private var interpretingEvent: NSEvent?

    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { acceptsPointer ? super.hitTest(point) : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func becomeFirstResponder() -> Bool {
        isFirstResponder = true
        updateActive()
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFirstResponder = false
        updateActive()
        inputContext?.discardMarkedText()
        markedText = NSAttributedString()
        onFocusChange?(false)
        return true
    }

    private var keyObservers: [EventSubscription] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The coalescer is the old window's: what waits there is for a window the view left.
        dropFramePointer()
        keyObservers.removeAll()
        if window == nil, isFirstResponder { isFirstResponder = false }
        if let window {
            // A window that stops being key takes the keyboard with it: release held keys. The window's one observer
            // per notice (WindowEvents) calls it, shown or hidden: a held key must be released either way.
            let events = WindowEvents.of(window)
            keyObservers = [
                events.subscribe(NSWindow.didBecomeKeyNotification, owner: "RemoteInputCaptureView") { [weak self] in self?.updateActive() },
                events.subscribe(NSWindow.didResignKeyNotification, owner: "RemoteInputCaptureView") { [weak self] in self?.updateActive() },
            ]
        }
        updateActive()
    }

    /// Read by mouse Back and Forward (`MouseSideButtons`): in control mode buttons 4 and 5 go
    /// to the host like every other button, so cmux does not navigate on them.
    var forwardsMouseButtons: Bool { controlMode }

    private func updateActive() {
        controller.isActive = controlMode && isFirstResponder && window?.isKeyWindow != false
    }

    /// Gives the keyboard back to the viewer.
    func releaseKeyboard() {
        guard let window, window.firstResponder === self else { return }
        window.makeFirstResponder(nil)
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        return handleKeyDown(event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) { super.keyDown(with: event) }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        flushPointer()
        switch controller.keyDown(event) {
        case .handled: return true
        case .local: return false
        case .textInput:
            interpretingEvent = event
            interpretKeyEvents([event])
            interpretingEvent = nil
            return true
        }
    }

    override func keyUp(with event: NSEvent) {
        flushPointer()
        controller.keyUp(event)
    }

    override func flagsChanged(with event: NSEvent) {
        flushPointer()
        controller.flagsChanged(event)
    }

    // MARK: Pointer

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    // local-monitor-allow: pointerMoved posts to the window's FrameInputCoalescer (pointerFrameRemoteInput) and forwards each move at once without it; buttons and keys flush what waits first, so the host gets every event in order
    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    // local-monitor-allow: as mouseMoved: the window's FrameInputCoalescer, the host's events kept in order
    override func mouseDragged(with event: NSEvent) { pointerMoved(event) }
    override func rightMouseDragged(with event: NSEvent) { pointerMoved(event) }
    override func otherMouseDragged(with event: NSEvent) { pointerMoved(event) }

    override func mouseDown(with event: NSEvent) { press(event, down: true) }
    override func mouseUp(with event: NSEvent) { press(event, down: false) }
    override func rightMouseDown(with event: NSEvent) { press(event, down: true) }
    override func rightMouseUp(with event: NSEvent) { press(event, down: false) }
    override func otherMouseDown(with event: NSEvent) { press(event, down: true) }
    override func otherMouseUp(with event: NSEvent) { press(event, down: false) }

    /// A scroll in the middle of its gesture, or a wheel notch, waits for the frame; a phase edge
    /// (began, ended, momentum began) goes at once, after what waits. A pane that sends nothing to
    /// the host (view mode, not first responder) posts nothing: it never wakes the window's frame.
    // local-monitor-allow: a mid-gesture scroll goes through the window's FrameInputCoalescer, a phase edge flushes it and goes at once: the host's wheel events keep their order
    override func scrollWheel(with event: NSEvent) { // perf-hot: 2us pointer-coalesce (every scroll over a remote desktop)
        if event.isMergeableScroll {
            guard controller.isActive else { return }
            if let consumer = framePointerConsumer() {
                consumer.post(event)
                return
            }
        }
        flushPointer()
        controller.scroll(event)
    }

    /// Delivers the moves and scrolls that wait for the frame now: a discrete event (a button, a
    /// key, a system shortcut) is about to go to the host, and must not pass them.
    func flushPointer() { framePointer?.flush() }

    /// A move or drag for the host. A pane that sends nothing to the host posts nothing, as for scrolls.
    private func pointerMoved(_ event: NSEvent) { // perf-hot: 2us pointer-coalesce (every move and drag over a remote desktop)
        guard controller.isActive else { return }
        if let consumer = framePointerConsumer() {
            consumer.post(event)
        } else {
            movePointer(to: convert(event.locationInWindow, from: nil), clamped: event.type != .mouseMoved)
        }
    }

    /// One frame delivery: the latest point of the merged moves or drags, or the summed scroll.
    private func deliver(_ input: PointerCoalescedInput) { // perf-hot: 2us pointer-coalesce (every frame delivery to the host)
        let record = input.latest
        switch input.kind {
        case .move, .drag:
            movePointer(to: convert(NSPoint(x: record.location.x, y: record.location.y), from: nil), clamped: input.kind == .drag)
        case .scroll:
            let phases = record.scrollPhase.appKitPhases
            controller.scroll(deltaX: input.scrollDelta.x, deltaY: input.scrollDelta.y, precise: record.hasPreciseScrollingDeltas,
                              phase: phases.phase, momentumPhase: phases.momentum)
        }
    }

    private func framePointerConsumer() -> PointerFrameConsumer? {
        if let framePointer { return framePointer }
        guard let pointerFrames, let window else { return nil }
        let consumer = pointerFrames.coalescer(for: window).consumer(owner: "RemoteInputCaptureView") { [weak self] input in
            self?.deliver(input)
        }
        framePointer = consumer
        return consumer
    }

    private func dropFramePointer() {
        framePointer?.cancel()
        framePointer = nil
    }

    /// A drag keeps going outside the picture (clamped to its edge); a plain move outside it is not sent.
    private func movePointer(to point: NSPoint, clamped: Bool) {
        guard let geometry = geometry() else { return }
        if clamped {
            controller.pointer(geometry.clampedStreamPixel(at: point))
        } else if let pixel = geometry.streamPixel(at: point) {
            controller.pointer(pixel)
        }
    }

    private func press(_ event: NSEvent, down: Bool) {
        flushPointer()
        if down { onMouseDown?() }
        if down, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let geometry = geometry(), let button = RemoteMouseButton(event: event) else { return }
        let point = convert(event.locationInWindow, from: nil)
        if down {
            guard let pixel = geometry.streamPixel(at: point) else { return }
            controller.button(button, down: true, at: pixel)
        } else {
            controller.button(button, down: false, at: geometry.clampedStreamPixel(at: point))
        }
    }
}

extension RemoteInputCaptureView: @MainActor NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = NSAttributedString()
        controller.commitText(text)
    }

    override func doCommand(by selector: Selector) {
        // The input method did not turn the key into text: send the key itself.
        if let event = interpretingEvent { controller.sendPhysical(for: event) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
    }

    func unmarkText() { markedText = NSAttributedString() }
    func selectedRange() -> NSRange { NSRange(location: markedText.length, length: 0) }
    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// The candidate window sits at the pane's center: the remote caret is
    /// unknown to the viewer.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let local = NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 18)
        guard let window else { return local }
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}

extension NSEvent {
    /// A scroll a newer scroll of the same phase may be merged with: one in the middle of its gesture
    /// (changed, or momentum changed), or a phaseless wheel notch, as Chromium merges wheels of equal
    /// phase, none included (`WebMouseWheelEvent::CanCoalesce`,
    /// `third_party/blink/common/input/web_mouse_wheel_event.cc`). A gesture's edges (may begin,
    /// began, ended, cancelled, momentum began and ended) are not.
    nonisolated package var isMergeableScroll: Bool {
        type == .scrollWheel
            && ((phase.isEmpty && momentumPhase.isEmpty) || phase == .changed || momentumPhase == .changed)
    }
}

extension InputScrollPhase {
    /// The AppKit gesture and momentum phases of a merged scroll. Only mid-gesture scrolls and wheel
    /// notches merge (``NSEvent/isMergeableScroll``), so `.momentum` is momentum changed.
    nonisolated package var appKitPhases: (phase: NSEvent.Phase, momentum: NSEvent.Phase) {
        switch self {
        case .none: ([], [])
        case .mayBegin: (.mayBegin, [])
        case .began: (.began, [])
        case .changed: (.changed, [])
        case .ended: (.ended, [])
        case .cancelled: (.cancelled, [])
        case .momentum: ([], .changed)
        case .momentumEnded: ([], .ended)
        }
    }
}
