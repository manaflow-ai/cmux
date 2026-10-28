public import AppKit
import CoreGraphics

/// Key repeat is a real input stream, never a backlog (Lawrence 2026-10-28, repeat-runoff.md 1a and
/// hold-shortcuts-ux.md 1: "if i hold cmd t then stop holding it, it still creates new stuff for a while").
///
/// A held shortcut acts once per repeat event the system delivers while the key is down. When one action costs
/// more main-thread time than the repeat interval, repeats wait in the event queue and used to run after the key
/// went up. The router asks this gate before it runs a shortcut's action for a key-down:
/// - a physical press (not `NSEvent.isARepeat`) always acts, at any speed (input-principles.md: presses all count);
/// - a repeat of a key that is no longer down acts on nothing the person still holds: dropped;
/// - a repeat that waited longer than one repeat interval is behind a newer repeat of the same key (the system
///   makes one per interval): dropped, so the newest one acts;
/// - at most one repeat action per display frame per key.
///
/// The gate reads the key state once per repeat of an action shortcut (at most one per frame), never per typed key,
/// and the event's own time: no queue walk and no wait.
public struct KeyRepeatGate {
    /// Whether the key with this virtual key code is down now. The app reads the session's key state; tests set it.
    public var keyIsDown: @MainActor (UInt16) -> Bool = { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
    /// The system key-repeat interval (System Settings > Keyboard), in seconds.
    public var repeatInterval: @MainActor () -> TimeInterval = { NSEvent.keyRepeatInterval }
    /// The clock of `NSEvent.timestamp` (seconds of system uptime).
    public var now: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// When each key's last repeat acted (its `now`).
    private var lastRepeatActed: [UInt16: TimeInterval] = [:]
    /// Repeats dropped since launch, by reason (`debug.key` and the bench read them).
    public private(set) var dropped = Dropped()

    /// Counts of dropped repeats by reason.
    public struct Dropped: Equatable, Sendable {
        /// Repeats of a key that was no longer down.
        public var released = 0
        /// Repeats behind a newer repeat of the same key.
        public var stale = 0
        /// Repeats in the same display frame as the key's last repeat action.
        public var sameFrame = 0
    }

    /// A gate with the system's key state, repeat interval and clock.
    public init() {}

    /// Whether `event`, a key-down whose shortcut would run an action, may run it now.
    /// `frame`: the display refresh interval of the event's window.
    @MainActor
    public mutating func admits(_ event: NSEvent, frame: TimeInterval) -> Bool {
        admits(keyCode: event.keyCode, isRepeat: event.isARepeat, made: event.timestamp, frame: frame)
    }

    /// ``admits(_:frame:)`` on the event's fields.
    @MainActor
    public mutating func admits(keyCode: UInt16, isRepeat: Bool, made: TimeInterval, frame: TimeInterval) -> Bool {
        // A physical press always acts; it starts the key's repeat stream afresh.
        guard isRepeat else {
            lastRepeatActed[keyCode] = nil
            return true
        }
        guard keyIsDown(keyCode) else {
            dropped.released += 1
            return false
        }
        let time = now()
        // The system makes one repeat per interval: one that waited longer is behind a newer one (or the key-up).
        guard time - made <= max(repeatInterval(), frame) else {
            dropped.stale += 1
            return false
        }
        if let last = lastRepeatActed[keyCode], time - last < frame {
            dropped.sameFrame += 1
            return false
        }
        lastRepeatActed[keyCode] = time
        return true
    }
}
