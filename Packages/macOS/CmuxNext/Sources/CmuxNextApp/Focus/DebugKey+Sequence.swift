#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextSettings

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
/// Step: `{"key_code": 30, "down": true, "after_ms": 5}`; `"repeat": true` marks a key-down
/// as a held key's auto-repeat (`NSEvent.isARepeat`). The sequence starts when this call runs
/// (`base_s` in the reply, in `NSEvent.timestamp`'s seconds since boot), and each
/// event's timestamp is its intended press time, the base plus its offset, whenever the main
/// thread gets to post it: as with hardware keys, whose timestamp is set at HID time, an event
/// that waits behind a busy main thread carries that wait in its input age. One task posts every
/// step in order at its offset. Returns at once with the number of steps scheduled, the base and
/// the duration (the last lands after the sum of the gaps). A new sequence cancels the one playing.
extension DebugKey {
    private static let modifierFlags: [UInt16: CGEventFlags] = [
        55: .maskCommand, 54: .maskCommand, 56: .maskShift, 60: .maskShift,
        59: .maskControl, 62: .maskControl, 58: .maskAlternate, 61: .maskAlternate,
    ]

    /// One planned event: what to post and its offset from the sequence's start.
    private struct Step {
        let keyCode: CGKeyCode
        let down: Bool
        let isModifier: Bool
        let flags: CGEventFlags
        let isRepeat: Bool
        let offset: Duration
    }

    /// The sequence being played.
    @MainActor private static var playing: Task<Void, Never>?

    @MainActor static func sendSequence<C: Clock<Duration>>(_ steps: [JSONValue], clock: C = ContinuousClock()) -> JSONValue {
        playing?.cancel()
        playing = nil
        var flags: CGEventFlags = []
        var offset = Duration.zero
        var planned: [Step] = []
        for step in steps {
            guard let code = step["key_code"]?.intValue, let down = step["down"]?.boolValue else {
                return .object(["error": .string("each step needs key_code and down")])
            }
            offset += .microseconds(Int64(((step["after_ms"]?.doubleValue ?? 0) * 1000).rounded()))
            let modifier = modifierFlags[UInt16(code)]
            if let modifier { if down { flags.insert(modifier) } else { flags.remove(modifier) } }
            planned.append(Step(keyCode: CGKeyCode(code), down: down, isModifier: modifier != nil, flags: flags,
                                isRepeat: down && step["repeat"]?.boolValue == true, offset: offset))
        }
        // The start in the event system's own units: `CGEventTimestamp` is documented as nanoseconds, yet
        // it follows the HID clock, whose ticks are not nanoseconds on every Mac. A fresh event's timestamp
        // and the seconds AppKit reads from it give the base and the scale for every step's offset.
        let source = CGEventSource(stateID: .privateState)
        guard let probe = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let baseSeconds = NSEvent(cgEvent: probe)?.timestamp, baseSeconds > 0 else {
            return .object(["error": .string("no event timestamp to start the sequence from")])
        }
        let base = probe.timestamp, ticksPerSecond = Double(base) / baseSeconds, start = clock.now
        playing = Task { @MainActor in
            for step in planned {
                // wakeup-allow: each sleep is the next step's own deadline in the sequence (bounded by its gaps, cancelled by the next sequence), not a poll
                do { try await clock.sleep(until: start.advanced(by: step.offset), tolerance: nil) } catch { return }
                guard let cgEvent = CGEvent(keyboardEventSource: source, virtualKey: step.keyCode, keyDown: step.down) else { continue }
                if step.isModifier { cgEvent.type = .flagsChanged }
                cgEvent.flags = step.flags
                if step.isRepeat { cgEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
                cgEvent.timestamp = base + CGEventTimestamp((seconds(step.offset) * ticksPerSecond).rounded())
                if let event = NSEvent(cgEvent: cgEvent) { NSApp.postEvent(event, atStart: false) }
            }
        }
        return .object(["scheduled": .number(Double(planned.count)), "base_s": .number(baseSeconds),
                        "duration_ms": .number(seconds(offset) * 1000)])
    }
}

/// `duration` in seconds (never negative: the gaps add up from zero).
private func seconds(_ duration: Duration) -> Double {
    let (whole, attoseconds) = duration.components
    return max(0, Double(whole) + Double(attoseconds) / 1e18)
}
#endif
