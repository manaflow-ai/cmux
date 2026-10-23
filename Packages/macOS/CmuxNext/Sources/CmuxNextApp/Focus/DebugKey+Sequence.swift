#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextSettings
import CmuxNextWakeups

/// `debug.key {"sequence": [...]}` (DEBUG builds): a keyboard's raw
/// transitions, in order and with their gaps, as a remapper such as
/// Karabiner's virtual keyboard sends them (Leo 2026-10-12: left_command,
/// left_shift, close_bracket, ~5 ms apart; left_control, then tab ~270 ms
/// later, held ~175 ms). Each step is a virtual key code going down or up;
/// a modifier key is a flags-changed event. Every event is built as a
/// `CGEvent` from the key code and the held modifiers, so the system layout
/// fills in its characters as for hardware (Shift-] types "}"), and is
/// posted to this app's event queue: it takes the path a real key does
/// (`nextEvent`, local monitors, `sendEvent`, the key window). Never posts
/// to another process.
///
/// Step: `{"key_code": 30, "down": true, "after_ms": 5}`; returns at once
/// with the number of steps scheduled (the last lands after the sum of the
/// gaps).
extension DebugKey {
    private static let modifierFlags: [UInt16: CGEventFlags] = [
        55: .maskCommand, 54: .maskCommand, 56: .maskShift, 60: .maskShift,
        59: .maskControl, 62: .maskControl, 58: .maskAlternate, 61: .maskAlternate,
    ]

    /// The sequence being played: its events and the timer that posts each.
    @MainActor private static var queued: [NSEvent] = []
    @MainActor private static var timers: [DemandTimer] = []

    @MainActor static func sendSequence(_ steps: [JSONValue]) -> JSONValue {
        timers.forEach { $0.cancel() }
        timers = []
        queued = []
        let source = CGEventSource(stateID: .privateState)
        var flags: CGEventFlags = []
        var delay = 0.0
        var scheduled = 0
        for step in steps {
            guard let code = step["key_code"]?.intValue, let down = step["down"]?.boolValue else {
                return .object(["error": .string("each step needs key_code and down")])
            }
            delay += (step["after_ms"]?.doubleValue ?? 0) / 1000
            let keyCode = CGKeyCode(code)
            let modifier = modifierFlags[UInt16(code)]
            if let modifier { if down { flags.insert(modifier) } else { flags.remove(modifier) } }
            guard let cgEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            if modifier != nil { cgEvent.type = .flagsChanged }
            cgEvent.flags = flags
            guard let event = NSEvent(cgEvent: cgEvent) else { continue }
            scheduled += 1
            queued.append(event)
            // Posted at its offset from now: the gaps are the sequence's, not this call's.
            let index = queued.count - 1, timer = DemandTimer(owner: "debug.key.sequence")
            timer.schedule(after: .milliseconds(Int(delay * 1000))) { @MainActor in
                if queued.indices.contains(index) { NSApp.postEvent(queued[index], atStart: false) }
            }
            timers.append(timer)
        }
        return .object(["scheduled": .number(Double(scheduled)), "duration_ms": .number(delay * 1000)])
    }
}
#endif
