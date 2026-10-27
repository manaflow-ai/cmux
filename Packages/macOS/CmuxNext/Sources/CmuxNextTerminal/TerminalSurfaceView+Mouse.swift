public import AppKit
import GhosttyNextKit

// Mouse, scroll, pressure, and cursor shape. Ghostty turns these into
// selection or, when the program enabled a mouse mode, into mouse reports
// that come back through `io_write_cb` (ghostty.h:1643-1655).
extension TerminalSurfaceView {
    public override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        session?.surfaceClicked()
        if !isFirstResponder { window?.makeFirstResponder(self) }
        // A Cmd-press on a URL a program broke onto rows is this view's (TerminalLinkPointer).
        if linkPointer.mouseDown(event) { return }
        sendLeftPress(event)
    }

    public override func mouseUp(with event: NSEvent) {
        previousPressureStage = 0
        defer {
            linkPressInCapture = false
            if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
        }
        if linkPointer.mouseUp(event) { return }
        sendButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, phase: .followingPress)
    }

    public override func otherMouseDown(with event: NSEvent) {
        sendButton(event, state: GHOSTTY_MOUSE_PRESS, button: Self.button(for: event.buttonNumber))
    }

    public override func otherMouseUp(with event: NSEvent) {
        sendButton(event, state: GHOSTTY_MOUSE_RELEASE, button: Self.button(for: event.buttonNumber))
    }

    /// When the program captured the mouse the right button goes to it;
    /// otherwise AppKit shows ``menu(for:)``.
    public override func rightMouseDown(with event: NSEvent) {
        if sendButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT) { return }
        super.rightMouseDown(with: event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        if sendButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT) { return }
        super.rightMouseUp(with: event)
    }

    public override func mouseMoved(with event: NSEvent) {
        linkPointer.movedWithoutButton()
        sendPosition(event)
    }
    public override func mouseDragged(with event: NSEvent) { sendPosition(event, phase: .followingPress) }
    public override func rightMouseDragged(with event: NSEvent) { sendPosition(event) }
    public override func otherMouseDragged(with event: NSEvent) { sendPosition(event) }
    public override func mouseEntered(with event: NSEvent) { sendPosition(event) }

    /// Moves Ghostty's pointer off-grid so link hover state clears.
    public override func mouseExited(with event: NSEvent) {
        linkPointer.exited()
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.mods(event.modifierFlags))
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        // The wheel goes with the real keys: a Cmd-hover's added Shift must not turn it sideways
        // in a program that has the mouse.
        if pointerFlags(event.modifierFlags) != event.modifierFlags {
            let point = convert(event.locationInWindow, from: nil)
            ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, GhosttyInput.mods(event.modifierFlags))
        }
        var deltaX = event.scrollingDeltaX
        var deltaY = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            // Same trackpad gain Ghostty.app applies before
            // `mouse-scroll-multiplier`, so scrolling feels identical.
            deltaX *= 2
            deltaY *= 2
        }
        ghostty_surface_mouse_scroll(surface, deltaX, deltaY, Self.scrollMods(precise: precise, phase: event.momentumPhase))
    }

    public override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(max(event.stage, 0)), Double(event.pressure))
        // Force click (stage 2) opens Quick Look once per press.
        defer { previousPressureStage = event.stage }
        guard previousPressureStage < 2, event.stage == 2,
              UserDefaults.standard.bool(forKey: "com.apple.trackpad.forceClick") else { return }
        quickLook(with: event)
    }

    public override func quickLook(with event: NSEvent) {
        guard let surface else { return super.quickLook(with: event) }
        var text = ghostty_text_s()
        guard ghostty_surface_quicklook_word(surface, &text) else { return super.quickLook(with: event) }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return super.quickLook(with: event) }
        let word = String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let fontPointer = ghostty_surface_quicklook_font(surface) {
            attributes[.font] = Unmanaged<CTFont>.fromOpaque(fontPointer).takeRetainedValue()
        }
        // Ghostty reports the word's top-left in points, top-left origin;
        // the baseline sits one cell lower.
        let point = NSPoint(x: text.tl_px_x, y: bounds.height - text.tl_px_y - cellPointSize.height)
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
        guard let surface else { return false }
        if position { sendPosition(event, phase: phase ?? .move) }
        let flags = phase.map { pointerMods(event.modifierFlags).flags(event.modifierFlags, phase: $0) } ?? event.modifierFlags
        return clipboardRequests.asUserClipboardWrite {
            ghostty_surface_mouse_button(surface, state, button, GhosttyInput.mods(flags))
        }
    }

    private func sendPosition(_ event: NSEvent, phase: TerminalPointerMods.Phase = .move) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Ghostty expects points with a top-left origin.
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, GhosttyInput.mods(pointerFlags(event.modifierFlags, phase: phase)))
        if phase == .move { linkPointer.moved(to: point, flags: event.modifierFlags) }
    }

    /// The pointer state ``TerminalPointerMods`` decides from. The capture check takes the
    /// terminal's lock, so it runs only with Command alone held (or during a link click).
    func pointerMods(_ flags: NSEvent.ModifierFlags) -> TerminalPointerMods {
        let asks = TerminalPointerMods.commandOnly(flags) || TerminalPointerMods.commandChord(flags) || linkPressInCapture
        let captured = asks && surface.map { ghostty_surface_mouse_captured($0) } == true
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
        let momentum: ghostty_input_mouse_momentum_e = switch phase {
        case .began: GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        return ghostty_input_scroll_mods_t((precise ? 1 : 0) | (Int32(momentum.rawValue) << 1))
    }
}
