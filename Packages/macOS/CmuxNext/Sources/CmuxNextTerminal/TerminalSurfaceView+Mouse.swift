public import AppKit
import CmuxNextInputCore
import GhosttyNextKit

// Mouse, scroll, pressure, and cursor shape. Ghostty turns these into
// selection or, when the program enabled a mouse mode, into mouse reports
// that come back through `io_write_cb` (ghostty.h:1643-1655). With the
// feature `terminalPointerFrames`, moves, drags and mouse-reporting trackpad
// scrolls reach Ghostty at most twice per frame (``TerminalPointerFrames``);
// every other event delivers what is pending first.
extension TerminalSurfaceView {
    public override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            // wakeup-allow: bounded mouse reporting and hover links follow the pointer over a terminal behind another app,
            // as in Ghostty; moves arrive only while the pointer is over this surface's visible rect
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        pointerFrames?.flush()
        session?.surfaceClicked()
        if !isFirstResponder { window?.makeFirstResponder(self) }
        // A Cmd-press on a URL a program broke onto rows is this view's (TerminalLinkPointer).
        if linkPointer.mouseDown(event) { return }
        sendLeftPress(event)
    }

    public override func mouseUp(with event: NSEvent) {
        pointerFrames?.flush()
        previousPressureStage = 0
        defer {
            linkPressInCapture = false
            mouse.pressure(stage: 0, pressure: 0)
        }
        if linkPointer.mouseUp(event) { return }
        sendButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, phase: .followingPress)
    }

    public override func otherMouseDown(with event: NSEvent) {
        pointerFrames?.flush()
        sendButton(event, state: GHOSTTY_MOUSE_PRESS, button: Self.button(for: event.buttonNumber))
    }

    public override func otherMouseUp(with event: NSEvent) {
        pointerFrames?.flush()
        sendButton(event, state: GHOSTTY_MOUSE_RELEASE, button: Self.button(for: event.buttonNumber))
    }

    /// When the program captured the mouse the right button goes to it;
    /// otherwise AppKit shows ``menu(for:)``.
    public override func rightMouseDown(with event: NSEvent) {
        pointerFrames?.flush()
        if sendButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT) { return }
        super.rightMouseDown(with: event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        pointerFrames?.flush()
        if sendButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT) { return }
        super.rightMouseUp(with: event)
    }

    public override func mouseMoved(with event: NSEvent) { // perf-hot: 1ms terminal-pointer (every move over a terminal)
        linkPointer.movedWithoutButton()
        if pointerFrames?.post(event, in: window) == true { return }
        sendPosition(event)
    }

    public override func mouseDragged(with event: NSEvent) { // perf-hot: 1ms terminal-pointer (every left drag event)
        if pointerFrames?.post(event, in: window) == true { return }
        sendPosition(event, phase: .followingPress)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        if pointerFrames?.post(event, in: window) == true { return }
        sendPosition(event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        if pointerFrames?.post(event, in: window) == true { return }
        sendPosition(event)
    }

    public override func mouseEntered(with event: NSEvent) {
        pointerFrames?.flush()
        sendPosition(event)
    }

    /// Moves Ghostty's pointer off-grid so link hover state clears.
    public override func mouseExited(with event: NSEvent) {
        pointerFrames?.flush()
        linkPointer.exited()
        mouse.position(x: -1, y: -1, mods: GhosttyInput.mods(event.modifierFlags))
    }

    /// A trackpad scroll while the program has the mouse waits for the frame, summed per phase
    /// (``TerminalPointerFrames``); a scroll through the scrollback and a wheel's lines go at once.
    public override func scrollWheel(with event: NSEvent) { // perf-hot: 1ms terminal-pointer (every scroll event)
        if let pointerFrames, event.hasPreciseScrollingDeltas, scrollReportsToProgram(event),
           pointerFrames.post(event, in: window) { return }
        pointerFrames?.flush()
        sendScroll(x: event.scrollingDeltaX, y: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                   momentum: Self.momentum(event.momentumPhase), flags: event.modifierFlags,
                   at: convert(event.locationInWindow, from: nil))
    }

    /// One delivery of ``TerminalPointerFrames``: a move or drag at its latest point, or a scroll
    /// phase's summed distance, with the latest event's keys.
    func deliverPointer(_ input: PointerCoalescedInput) { // perf-hot: 1ms terminal-pointer (each leading or trailing delivery)
        guard window != nil else { return }
        let latest = input.latest
        let flags = NSEvent.ModifierFlags(rawValue: latest.modifierFlags.rawValue)
        let point = convert(NSPoint(x: latest.location.x, y: latest.location.y), from: nil)
        switch input.kind {
        case .move:
            sendPosition(at: point, flags: flags, phase: .move)
        case .drag:
            sendPosition(at: point, flags: flags, phase: latest.type == .leftMouseDragged ? .followingPress : .move)
        case .scroll:
            sendScroll(x: input.scrollDelta.x, y: input.scrollDelta.y, precise: latest.hasPreciseScrollingDeltas,
                       momentum: Self.momentum(latest.scrollPhase), flags: flags, at: point)
        }
    }

    public override func pressureChange(with event: NSEvent) {
        sendPressure(stage: event.stage, pressure: event.pressure)
        // Force click (stage 2) opens Quick Look once per press.
        defer { previousPressureStage = event.stage }
        guard surface != nil, previousPressureStage < 2, event.stage == 2,
              UserDefaults.standard.bool(forKey: "com.apple.trackpad.forceClick") else { return }
        quickLook(with: event)
    }

    /// A force-touch stage and pressure: Ghostty applies it at its last pointer position, so the
    /// moves and drags waiting for the frame go first.
    func sendPressure(stage: Int, pressure: Float) {
        pointerFrames?.flush()
        mouse.pressure(stage: UInt32(max(stage, 0)), pressure: Double(pressure))
    }

    /// Ghostty looks up the word at its last pointer position: the waiting moves and drags go first.
    public override func quickLook(with event: NSEvent) {
        pointerFrames?.flush()
        guard let surface else { return super.quickLook(with: event) }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        guard let read = unsafe GhosttyTextRead(quickLookWordOf: surface), !read.bytes.isEmpty else {
            return super.quickLook(with: event)
        }
        var attributes: [NSAttributedString.Key: Any] = [:]
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        if let font = unsafe GhosttyTextRead.quickLookFont(surface) {
            attributes[.font] = font
        }
        // Ghostty reports the word's top-left in points, top-left origin;
        // the baseline sits one cell lower.
        let point = NSPoint(x: read.topLeft.x, y: bounds.height - read.topLeft.y - cellPointSize.height)
        let word = read.string
        showDefinition(for: NSAttributedString(string: word, attributes: attributes), at: point)
    }

    // MARK: Cursor

    public override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    func setCursor(_ newCursor: NSCursor) {
        guard newCursor != cursor else { return }
        cursor = newCursor
        window?.invalidateCursorRects(for: self)
        // The pointer's own location: a key event or a late link-filter answer carries none.
        if let window, isShown, window.isVisible, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            newCursor.set()
        }
    }

    static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: .arrow
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: .crosshair
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_ALIAS: .dragLink
        case GHOSTTY_MOUSE_SHAPE_COPY: .dragCopy
        case GHOSTTY_MOUSE_SHAPE_NO_DROP, GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_GRAB, GHOSTTY_MOUSE_SHAPE_MOVE, GHOSTTY_MOUSE_SHAPE_ALL_SCROLL: .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: .closedHand
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE: .resizeUp
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE: .resizeDown
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE: .resizeRight
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE: .resizeLeft
        default: .arrow
        }
    }

    // MARK: Helpers

    /// A left press: the move first, with the keys that let Ghostty find a link under it while
    /// the program has the mouse, then the press, as a link click when it found one
    /// (``TerminalPointerMods``).
    private func sendLeftPress(_ event: NSEvent) {
        sendPosition(event)
        let mods = pointerMods(event.modifierFlags)
        linkPressInCapture = mods.linkGesture(event.modifierFlags, phase: .press) || mods.chordGesture(event.modifierFlags, phase: .press)
        sendButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, phase: .press, position: false)
    }

    @discardableResult
    private func sendButton(_ event: NSEvent, state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e,
                            phase: TerminalPointerMods.Phase? = nil, position: Bool = true) -> Bool {
        if position { sendPosition(event, phase: phase ?? .move) }
        let flags = phase.map { pointerMods(event.modifierFlags).flags(event.modifierFlags, phase: $0) } ?? event.modifierFlags
        return clipboardRequests.asUserClipboardWrite {
            mouse.button(state, button, mods: GhosttyInput.mods(flags))
        }
    }

    private func sendPosition(_ event: NSEvent, phase: TerminalPointerMods.Phase = .move) {
        sendPosition(at: convert(event.locationInWindow, from: nil), flags: event.modifierFlags, phase: phase)
    }

    /// The pointer at `point` (view coordinates) with `flags` held.
    private func sendPosition(at point: NSPoint, flags: NSEvent.ModifierFlags, phase: TerminalPointerMods.Phase) {
        // Ghostty expects points with a top-left origin.
        mouse.position(x: point.x, y: bounds.height - point.y, mods: GhosttyInput.mods(pointerFlags(flags, phase: phase)))
        if phase == .move { linkPointer.moved(to: point, flags: flags) }
    }

    /// A scroll of (`x`, `y`) with the pointer at `point` (view coordinates) and `flags` held.
    private func sendScroll(x: Double, y: Double, precise: Bool, momentum: ghostty_input_mouse_momentum_e,
                            flags: NSEvent.ModifierFlags, at point: NSPoint) {
        // The wheel goes with the real keys: a Cmd-hover's added Shift must not turn it sideways
        // in a program that has the mouse.
        if pointerFlags(flags) != flags {
            mouse.position(x: point.x, y: bounds.height - point.y, mods: GhosttyInput.mods(flags))
        }
        // Same trackpad gain Ghostty.app applies before `mouse-scroll-multiplier`, so scrolling
        // feels identical.
        let gain = precise ? 2.0 : 1.0
        mouse.scroll(x: x * gain, y: y * gain, mods: Self.scrollMods(precise: precise, momentum: momentum))
    }

    /// Whether the program gets this scroll as mouse reports, by ``TerminalMouseCapture``'s last
    /// answer. A gesture's first event, or one with no phase, asks again, so a program that turned
    /// reporting on or off is heard from the next events on.
    private func scrollReportsToProgram(_ event: NSEvent) -> Bool {
        let startsGesture = event.phase.contains(.began) || event.phase.contains(.mayBegin)
            || (event.phase.isEmpty && event.momentumPhase.isEmpty)
        if startsGesture { mouseCapture.refresh() }
        return mouseCapture.programHasMouse
    }

    /// The pointer state ``TerminalPointerMods`` decides from. The capture check takes the
    /// terminal's lock, so it runs only with Command alone held (or during a link click).
    func pointerMods(_ flags: NSEvent.ModifierFlags) -> TerminalPointerMods {
        let asks = TerminalPointerMods.commandOnly(flags) || TerminalPointerMods.commandChord(flags) || linkPressInCapture
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        let captured = unsafe asks && surface.map { unsafe ghostty_surface_mouse_captured($0) } == true
        return TerminalPointerMods(captured: captured, overLink: session?.model.hoveredLink != nil, linkPress: linkPressInCapture)
    }

    /// `flags` as Ghostty gets them with a pointer event in `phase` (``TerminalPointerMods``).
    func pointerFlags(_ flags: NSEvent.ModifierFlags, phase: TerminalPointerMods.Phase = .move) -> NSEvent.ModifierFlags {
        pointerMods(flags).flags(flags, phase: phase)
    }

    private static func button(for number: Int) -> ghostty_input_mouse_button_e {
        switch number {
        case 0: GHOSTTY_MOUSE_LEFT
        case 1: GHOSTTY_MOUSE_RIGHT
        case 2: GHOSTTY_MOUSE_MIDDLE
        case 3: GHOSTTY_MOUSE_FOUR
        case 4: GHOSTTY_MOUSE_FIVE
        case 5: GHOSTTY_MOUSE_SIX
        case 6: GHOSTTY_MOUSE_SEVEN
        case 7: GHOSTTY_MOUSE_EIGHT
        case 8: GHOSTTY_MOUSE_NINE
        case 9: GHOSTTY_MOUSE_TEN
        case 10: GHOSTTY_MOUSE_ELEVEN
        default: GHOSTTY_MOUSE_UNKNOWN
        }
    }

    /// Packed `ghostty_input_scroll_mods_t` (src/input/mouse.zig): bit 0 is
    /// precision, bits 1-3 the momentum phase.
    static func scrollMods(precise: Bool, phase: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        scrollMods(precise: precise, momentum: momentum(phase))
    }

    static func scrollMods(precise: Bool, momentum: ghostty_input_mouse_momentum_e) -> ghostty_input_scroll_mods_t {
        ghostty_input_scroll_mods_t((precise ? 1 : 0) | (Int32(momentum.rawValue) << 1))
    }

    /// Ghostty's momentum of an event's `momentumPhase`.
    static func momentum(_ phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
        switch phase {
        case .began: GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: GHOSTTY_MOUSE_MOMENTUM_NONE
        }
    }

    /// Ghostty's momentum of a coalesced scroll: a momentum run (its began merged with its changes)
    /// or the run's end; a scroll with the fingers down has none, as its events' `momentumPhase`.
    static func momentum(_ phase: InputScrollPhase) -> ghostty_input_mouse_momentum_e {
        switch phase {
        case .momentum: GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .momentumEnded: GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .none, .mayBegin, .began, .changed, .ended, .cancelled: GHOSTTY_MOUSE_MOMENTUM_NONE
        }
    }
}
