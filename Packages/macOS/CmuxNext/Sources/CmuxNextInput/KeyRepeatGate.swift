public import AppKit
import Carbon.HIToolbox
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
/// The action registry asks it once per repeat key-down that would run an action (`ActionRegistry.repeatGate`), so
/// every path a key takes to an action is gated in one place: the key router's table, a chord, a Chromium page's
/// unhandled key, a menu key equivalent. Typed keys never reach it. It reads the key state once per such repeat and
/// the event's own time: no queue walk and no wait.
///
/// Limits: while Secure Event Input is on (a password field, Secure Keyboard Entry) this process cannot read the key
/// state, so only the age rule applies (a backlog is cut to the newest repeat). The age limit is the system repeat
/// interval, or the gap between this key's last two repeats when that is longer (a remote screen client or a remapper
/// that repeats more slowly), so a slow repeat stream is never mistaken for a backlog.
public struct KeyRepeatGate {
    /// Whether the key with this virtual key code is down now with the event's Command and Control held. The app reads
    /// the session's key state (``systemKeyIsDown(_:_:)``); tests set it.
    public var keyIsDown: @MainActor (UInt16, NSEvent.ModifierFlags) -> Bool = KeyRepeatGate.systemKeyIsDown
    /// Keys a client holds down for this process (`debug.key {repeat: true}` until `{up: true}`): read as down.
    public var held: Set<UInt16> = []
    /// The system key-repeat interval (System Settings > Keyboard), in seconds.
    public var repeatInterval: @MainActor () -> TimeInterval = { NSEvent.keyRepeatInterval }
    /// The clock of `NSEvent.timestamp` (seconds of system uptime).
    public var now: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// When each key's last repeat acted (its `now`).
    private var lastRepeatActed: [UInt16: TimeInterval] = [:]
    /// When each key's last repeat was made (its event time), for the gap between repeats.
    private var lastRepeatMade: [UInt16: TimeInterval] = [:]
    /// The repeat interval and when it was read (read again at most once a second).
    private var interval: (value: TimeInterval, readAt: TimeInterval)?
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

    /// The session's key state: `keyCode` down with `flags`' Command and Control. True while Secure Event Input hides
    /// the state from this process (the age rule still applies).
    @MainActor
    public static func systemKeyIsDown(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        if IsSecureEventInputEnabled() { return true }
        guard CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) else { return false }
        let down = CGEventSource.flagsState(.combinedSessionState)
        if flags.contains(.command), !down.contains(.maskCommand) { return false }
        if flags.contains(.control), !down.contains(.maskControl) { return false }
        return true
    }

    /// Whether `event`, a key-down whose shortcut would run an action, may run it now.
    /// `frame`: the display refresh interval of the event's window.
    @MainActor
    public mutating func admits(_ event: NSEvent, frame: TimeInterval) -> Bool {
        admits(keyCode: event.keyCode, flags: event.modifierFlags, isRepeat: event.isARepeat, made: event.timestamp, frame: frame)
    }

    /// ``admits(_:frame:)`` on the event's fields.
    @MainActor
    public mutating func admits(keyCode: UInt16, flags: NSEvent.ModifierFlags = [], isRepeat: Bool, made: TimeInterval, frame: TimeInterval) -> Bool {
        true
    }
}
