public import AppKit
public import CmuxNextRemoteView

#if DEBUG
/// Turns AppKit events into rb/1 input events (remote-tab-protocol.md
/// section 6, JSON form), the opaque bytes of an rd service input event.
public nonisolated struct RemoteBrowserInputEncoder {
    public nonisolated init() {}
    /// rb modifier bits (`cmux_remote_browser::proto::modifiers`).
    public static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int64 {
        var bits: Int64 = 0
        if flags.contains(.shift) { bits |= 1 }
        if flags.contains(.control) { bits |= 1 << 1 }
        if flags.contains(.option) { bits |= 1 << 2 }
        if flags.contains(.command) { bits |= 1 << 3 }
        if flags.contains(.capsLock) { bits |= 1 << 4 }
        if flags.contains(.function) { bits |= 1 << 5 }
        return bits
    }

    /// A pointer event at `point` (pane points = page CSS pixels, or the
    /// popup's own CSS pixels for `surface` other than 0, the page); nil
    /// for event types that are not pointer input.
    public static func pointer(
        type: NSEvent.EventType, button: Int, clickCount: Int, modifierFlags: NSEvent.ModifierFlags, at point: CGPoint,
        surface: UInt32 = 0
    ) -> RemoteRdJSON? {
        let kind: String
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = "down"
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = "up"
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = "move"
        case .mouseEntered: kind = "enter"
        case .mouseExited: kind = "leave"
        default: return nil
        }
        // DOM buttons: 0 main, 1 auxiliary, 2 secondary; AppKit: 0 left, 1 right, 2 middle.
        let domButton: Int64 = switch button { case 1: 2; case 2: 1; default: Int64(button) }
        let pressed: Int64 = kind == "down" || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged
            ? [Int64(1), 4, 2][min(Int(domButton), 2)] : 0
        return .object([
            "e": .string("pointer"), "surface": .int(Int64(surface)), "kind": .string(kind),
            "x": .double(Double(point.x)), "y": .double(Double(point.y)),
            "button": .int(domButton), "buttons": .int(pressed), "click_count": .int(Int64(clickCount)),
            "modifiers": .int(modifiers(modifierFlags)), "pointer_type": .string("mouse"),
        ])
    }

    /// A pointer or wheel event at `point`. Popup surfaces take pointer
    /// input only (cmux-remote-browser `rp_input`), so a wheel on one is nil.
    public static func pointer(_ event: NSEvent, at point: CGPoint, surface: UInt32 = 0) -> RemoteRdJSON? {
        if event.type == .scrollWheel {
            return surface == 0 ? wheel(event, at: point) : nil
        }
        let clicks = [.mouseMoved, .mouseEntered, .mouseExited].contains(event.type) ? 0 : event.clickCount
        return pointer(
            type: event.type, button: appKitButton(event), clickCount: clicks, modifierFlags: event.modifierFlags, at: point,
            surface: surface)
    }

    /// Whether the host must get `event` even when newer input supersedes
    /// it: moves and mid-gesture wheel deltas may go, presses, releases,
    /// enter, leave and gesture edges may not.
    public static func mustDeliver(_ event: NSEvent) -> Bool {
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            false
        case .scrollWheel:
            !(event.phase == .changed || event.momentumPhase == .changed)
        default:
            true
        }
    }

    /// The AppKit button (0 left, 1 right, 2+ other): the event type decides
    /// left and right, since a synthesized right click can carry button 0.
    static func appKitButton(_ event: NSEvent) -> Int {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: 0
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: 1
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged: max(2, event.buttonNumber)
        default: 0
        }
    }

    /// A page wheel event at `point` (`wheel`): AppKit's scrolling deltas
    /// as they are (positive `dy` scrolls toward the top), in points when
    /// `precise` (trackpad, Magic Mouse) else in lines (a wheel notch), with
    /// the gesture and momentum phases Chromium needs for elastic scrolling.
    public static func wheel(
        dx: Double, dy: Double, precise: Bool, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase,
        modifierFlags: NSEvent.ModifierFlags, at point: CGPoint
    ) -> RemoteRdJSON {
        .object([
            "e": .string("wheel"), "surface": .int(0), "x": .double(Double(point.x)), "y": .double(Double(point.y)),
            "dx": .double(dx), "dy": .double(dy), "precise": .bool(precise),
            "phase": .string(phaseName(phase)), "momentum_phase": .string(phaseName(momentumPhase)),
            "modifiers": .int(modifiers(modifierFlags)),
        ])
    }

    public static func wheel(_ event: NSEvent, at point: CGPoint) -> RemoteRdJSON {
        wheel(
            dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas,
            phase: event.phase, momentumPhase: event.momentumPhase, modifierFlags: event.modifierFlags, at: point)
    }

    /// rb/1 `Phase` names; a stationary trackpad is a gesture still in progress.
    static func phaseName(_ phase: NSEvent.Phase) -> String {
        if phase.contains(.began) { return "began" }
        if phase.contains(.changed) || phase.contains(.stationary) { return "changed" }
        if phase.contains(.ended) { return "ended" }
        if phase.contains(.cancelled) { return "cancelled" }
        if phase.contains(.mayBegin) { return "may_begin" }
        return "none"
    }

    /// A key down or up; nil for other events (modifier changes ride on the
    /// next key's `modifiers`).
    public static func key(_ event: NSEvent) -> RemoteRdJSON? {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let code = domCode[event.keyCode] ?? "Unidentified"
        let text = event.type == .keyDown ? (event.characters ?? "") : ""
        let printable = text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
        let key = domKey[event.keyCode] ?? (printable && !text.isEmpty ? text : event.charactersIgnoringModifiers ?? "")
        return .object([
            "e": .string("key"), "surface": .int(0), "down": .bool(event.type == .keyDown),
            "code": .string(code), "key": .string(key), "text": .string(printable ? text : ""),
            "unmodified_text": .string(printable ? (event.charactersIgnoringModifiers ?? "") : ""),
            "modifiers": .int(modifiers(event.modifierFlags)), "repeat": .bool(event.type == .keyDown && event.isARepeat),
            "location": .int(0), "edit_commands": .array([]),
        ])
    }

    /// The bytes of one event, as the host reads them.
    public static func bytes(_ event: RemoteRdJSON) -> Data? {
        try? JSONEncoder().encode(event)
    }

    /// Keys whose DOM `key` is a name rather than the typed text.
    static let domKey: [UInt16: String] = [
        36: "Enter", 76: "Enter", 48: "Tab", 51: "Backspace", 117: "Delete", 53: "Escape",
        123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
    ]

    /// macOS virtual key codes to DOM `KeyboardEvent.code` (ANSI layout).
    static let domCode: [UInt16: String] = {
        var map: [UInt16: String] = [
            36: "Enter", 76: "NumpadEnter", 48: "Tab", 49: "Space", 51: "Backspace", 117: "Delete", 53: "Escape",
            123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
            115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
            27: "Minus", 24: "Equal", 33: "BracketLeft", 30: "BracketRight", 42: "Backslash", 41: "Semicolon",
            39: "Quote", 50: "Backquote", 43: "Comma", 47: "Period", 44: "Slash",
            56: "ShiftLeft", 60: "ShiftRight", 59: "ControlLeft", 62: "ControlRight", 58: "AltLeft", 61: "AltRight",
            55: "MetaLeft", 54: "MetaRight", 57: "CapsLock",
        ]
        let letters: [(UInt16, String)] = [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"), (38, "J"),
            (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"), (1, "S"), (17, "T"),
            (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
        ]
        for (code, letter) in letters { map[code] = "Key" + letter }
        let digits: [(UInt16, String)] = [(29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9")]
        for (code, digit) in digits { map[code] = "Digit" + digit }
        let functions: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in functions.enumerated() { map[code] = "F\(index + 1)" }
        return map
    }()
}
#endif
