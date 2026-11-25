import AppKit

/// One input event for a Chromium page, in the page's points from its top left (cef-helper-app-DESIGN.md 3.3): what
/// cmux's page view turns AppKit's events into. A presented page (``CEFHostedPageView``, in process) gives it to the shim
/// (``CEFPresentedInput``); the helper app's page (``ChromiumHostPageView``) writes it as a wire frame. The C++ side of
/// both is one translation too (`CEFShim/src/page_input.h`). Plain values: building one allocates nothing (the
/// `cef-host-input` hot path, `ChromiumHostInputAllocationTests`).
nonisolated enum ChromiumPageInput: Equatable, Sendable {
    case mouse(Mouse)
    case wheel(Wheel)
    case key(Key)
    case edit(Edit)

    /// A press, release, move or exit of the pointer.
    struct Mouse: Equatable, Sendable {
        enum Phase: Int32, Sendable { case move = 0, down = 1, up = 2, exit = 3 }
        var x: Int32
        var y: Int32
        var phase: Phase
        /// 0 left, 1 middle (or any other), 2 right.
        var button: Int32
        /// The press's click count (0 for a move or an exit).
        var clickCount: Int32
        /// The pressed buttons: 1 left, 2 right, 4 middle (NSEvent's order).
        var buttons: Int32
        /// `NSEvent.ModifierFlags`.
        var modifierFlags: UInt64
        /// The event's time, CLOCK_UPTIME_RAW nanoseconds (0 when unknown).
        var time: UInt64
    }

    /// A scroll with its phases (fork API 30 `cmux_browser_send_wheel`, the `CMUX_RP_PHASE_*` values).
    struct Wheel: Equatable, Sendable {
        var x: Double
        var y: Double
        /// Pixels, positive to scroll up and left (`scrollingDeltaX`/`Y`; a line wheel's lines turned into pixels).
        var dx: Double
        var dy: Double
        /// A trackpad or Magic Mouse (`hasPreciseScrollingDeltas`).
        var precise: Bool
        var phase: Int32
        var momentumPhase: Int32
        var modifierFlags: UInt64
        var time: UInt64
    }

    /// A key down, up or modifier change.
    struct Key: Equatable, Sendable {
        enum Phase: Int32, Sendable { case down = 0, up = 1, flagsChanged = 2 }
        var phase: Phase
        var keyCode: Int32
        /// The first UTF-16 unit of `characters` and of `charactersIgnoringModifiers` (0 for none or a modifier change).
        var character: UInt16
        var unmodifiedCharacter: UInt16
        var isRepeat: Bool
        var modifierFlags: UInt64
        var time: UInt64
    }

    /// An Edit menu command on the page's focused frame (the shim's and the wire's numbers).
    enum Edit: Int32, Sendable {
        case copy = 0, cut, paste, selectAll, undo, redo, delete, pasteAndMatchStyle
    }

    /// How many pixels Chromium takes for one line of a line wheel (`kScrollbarPixelsPerCocoaTick`).
    static let pixelsPerLine = 40.0

    /// `point` (in `view`'s coordinates) as page points from the view's top left.
    @MainActor
    static func pagePoint(_ point: NSPoint, in view: NSView) -> (x: Int32, y: Int32) {
        let y = view.isFlipped ? point.y : view.bounds.height - point.y
        return (Int32(point.x.rounded(.down)), Int32(y.rounded(.down)))
    }

    /// The pointer event `event` over `view` (`phase`, `button`: 0 left, 1 middle, 2 right).
    @MainActor
    static func mouse(_ event: NSEvent, in view: NSView, phase: Mouse.Phase, button: Int32) -> ChromiumPageInput { // perf-hot: 5us cef-host-input (every mouse event)
        let point = pagePoint(view.convert(event.locationInWindow, from: nil), in: view)
        let buttons = Int32(truncatingIfNeeded: NSEvent.pressedMouseButtons & 0x7)
        let clicks = phase == .move || phase == .exit ? 0 : Int32(event.clickCount)
        return .mouse(Mouse(x: point.x, y: point.y, phase: phase, button: button, clickCount: clicks, buttons: buttons,
                            modifierFlags: UInt64(event.modifierFlags.rawValue), time: nanoseconds(event.timestamp)))
    }

    /// The scroll `event` over `view`, with its phases.
    @MainActor
    static func wheel(_ event: NSEvent, in view: NSView) -> ChromiumPageInput { // perf-hot: 5us cef-host-input (every scroll event)
        let local = view.convert(event.locationInWindow, from: nil)
        let y = view.isFlipped ? local.y : view.bounds.height - local.y
        let precise = event.hasPreciseScrollingDeltas
        let scale = precise ? 1 : pixelsPerLine
        return .wheel(Wheel(x: Double(local.x), y: Double(y), dx: Double(event.scrollingDeltaX) * scale,
                            dy: Double(event.scrollingDeltaY) * scale, precise: precise, phase: wheelPhase(event.phase),
                            momentumPhase: wheelPhase(event.momentumPhase), modifierFlags: UInt64(event.modifierFlags.rawValue),
                            time: nanoseconds(event.timestamp)))
    }

    /// The key event `event` (a key down, up, or modifier change).
    static func key(_ event: NSEvent) -> ChromiumPageInput { // perf-hot: 5us cef-host-input (every key event)
        let phase: Key.Phase = switch event.type {
        case .keyUp: .up
        case .flagsChanged: .flagsChanged
        default: .down
        }
        var key = Key(phase: phase, keyCode: Int32(event.keyCode), character: 0, unmodifiedCharacter: 0,
                      isRepeat: phase == .flagsChanged ? false : event.isARepeat,
                      modifierFlags: UInt64(event.modifierFlags.rawValue), time: nanoseconds(event.timestamp))
        if phase != .flagsChanged {
            key.character = event.characters?.utf16.first ?? 0
            key.unmodifiedCharacter = event.charactersIgnoringModifiers?.utf16.first ?? 0
        }
        return .key(key)
    }

    /// `NSEvent.Phase` as a `CMUX_RP_PHASE_*` value (0 none, 1 may begin, 2 began, 3 changed, 4 ended, 5 cancelled).
    static func wheelPhase(_ phase: NSEvent.Phase) -> Int32 {
        if phase.contains(.mayBegin) { return 1 }
        if phase.contains(.began) { return 2 }
        if phase.contains(.changed) || phase.contains(.stationary) { return 3 }
        if phase.contains(.ended) { return 4 }
        if phase.contains(.cancelled) { return 5 }
        return 0
    }

    /// An event time (seconds since boot) as CLOCK_UPTIME_RAW nanoseconds.
    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        seconds > 0 ? UInt64(seconds * 1e9) : 0
    }
}

/// Where a page view's input goes: the in-process shim for a presented page (``CEFPresentedInput``), the wire for the
/// helper app's page.
@MainActor
protocol ChromiumPageInputSink: AnyObject {
    /// Forwards one input event to the page.
    func send(_ input: ChromiumPageInput)
    /// The page view took (`true`) or left (`false`) the keyboard of its window: the page's focus and active state.
    func focusChanged(_ focused: Bool)
    /// The key down `event` the page view forwards next: Chromium's key hooks see this event, not the one CEF rebuilds.
    func willForwardKey(_ event: NSEvent)
}

extension ChromiumPageInputSink {
    func willForwardKey(_ event: NSEvent) {}
}

/// The helper app's wire (`chromium_host_wire.h`): a page input as its frame.
nonisolated extension ChromiumHostFrame {
    /// `kMouse`: v0 x, v1 y, v2 phase, v3 button, v4 click count, v5 buttons; flags; t0.
    init(mouse: ChromiumPageInput.Mouse) {
        self.init(.mouse, v: .init(mouse.x, mouse.y, mouse.phase.rawValue, mouse.button, mouse.clickCount, mouse.buttons),
                  flags: mouse.modifierFlags, t0: mouse.time)
    }

    /// `kKey`: v0 phase, v1 key code, v2 repeat; flags; ch, unmod; t0.
    init(key: ChromiumPageInput.Key) {
        self.init(.key, v: .init(key.phase.rawValue, key.keyCode, key.isRepeat ? 1 : 0), flags: key.modifierFlags, t0: key.time)
        ch = key.character
        unmod = key.unmodifiedCharacter
    }
}
