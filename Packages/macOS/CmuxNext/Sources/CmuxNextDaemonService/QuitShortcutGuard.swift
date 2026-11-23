public import AppKit
public import CmuxNextActions
public import Foundation

/// Cmd-Q's guard against an accidental quit (https://github.com/manaflow-ai/cmux/issues/48621,
/// Chrome's "Warn Before Quitting"): the first press of the quit shortcut only asks "Quit cmux?";
/// holding the keys for ``holdDuration`` or pressing them again while it asks quits. The Quit
/// menu item, the Dock's Quit, the palette and every scripted quit are deliberate and never
/// pass through here.
public nonisolated struct QuitShortcutPresses: Equatable {
    /// How long the first press must be held (its key repeats) to quit.
    public static let holdDuration: TimeInterval = 0.8

    /// What a press of the quit shortcut does.
    public enum Outcome: Equatable {
        /// The first press: warn, and wait for the hold, a second press or the question's answer.
        case warn
        /// A repeat of the held first press before ``holdDuration``, or the same key-down seen twice.
        case wait
        /// Held long enough, or pressed again while armed: quit.
        case quit
    }

    /// The timestamp of the press that armed the guard, nil when none did.
    public private(set) var armedAt: TimeInterval?
    private var lastTimestamp: TimeInterval?

    public init() {}

    public var isArmed: Bool { armedAt != nil }

    /// Feeds one key-down of the quit shortcut.
    ///
    /// - Parameters:
    ///   - isRepeat: The key-down is an auto-repeat (the keys are held).
    ///   - timestamp: The event's timestamp (seconds since boot).
    public mutating func press(isRepeat: Bool, timestamp: TimeInterval) -> Outcome {
        // One key-down can reach both the repeat monitor and the action.
        if lastTimestamp == timestamp { return .wait }
        lastTimestamp = timestamp
        // A repeat is never a first press: the keys still held after a quit that was refused (Cancel on unsaved changes).
        guard let armedAt, timestamp >= armedAt else { return isRepeat ? .wait : arm(timestamp) }
        if isRepeat {
            // A repeat follows the press that armed: a new press would not repeat before it was counted.
            guard timestamp - armedAt >= Self.holdDuration else { return .wait }
            reset()
            return .quit
        }
        reset()
        return .quit
    }

    /// Disarms (the question was answered, the quit ran, the setting is off).
    public mutating func reset() {
        armedAt = nil
        lastTimestamp = nil
    }

    private mutating func arm(_ timestamp: TimeInterval) -> Outcome {
        armedAt = timestamp
        lastTimestamp = timestamp
        return .warn
    }
}

/// The AppKit side of ``QuitShortcutPresses``: decides a key-down of the quit shortcut and, while
/// the warning shows, watches the shortcut's key repeats (a held Cmd-Q) whether or not the key
/// dispatcher hands them to the Quit action. The App shows the warning and runs the quit.
@MainActor
public final class QuitShortcutGuard {
    public private(set) var presses = QuitShortcutPresses()
    private var monitor: Any?
    private var armedKeyCode: UInt16?
    /// The armed press's Command, Shift, Option and Control: a held key with other modifiers is another shortcut.
    private var armedModifiers: NSEvent.ModifierFlags?
    /// Runs the quit when the held shortcut reaches ``QuitShortcutPresses/holdDuration``.
    public var onHeldQuit: (() -> Void)?
    /// Ends the warning when the guard disarms (a quit, a timeout, the setting off).
    public var onDisarm: (() -> Void)?
    private let addMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any?
    private let removeMonitor: (Any) -> Void

    public init(addMonitor: @escaping (@escaping (NSEvent) -> NSEvent?) -> Any? = { NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: $0) },
                removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }) {
        self.addMonitor = addMonitor
        self.removeMonitor = removeMonitor
    }

    /// Whether this run of Quit waits instead of quitting. Only a person's in-app run from the
    /// shortcut (`event`, the key-down being dispatched) with the setting on (`enabled`) is guarded;
    /// its first press calls `warn` with the shortcut's keys ("⌘Q"), which answers whether the
    /// warning shows (no window to show it in: quit at once).
    public func holds(_ invocation: ActionInvocation, event: NSEvent?, enabled: Bool, warn: (_ shortcut: String) -> Bool) -> Bool {
        guard enabled, invocation.origin == .user, !invocation.viaControlSocket, !invocation.menuPick,
              let event, Self.isShortcutPress(event) else {
            disarm()
            return false
        }
        switch press(event) {
        case .quit:
            return false
        case .wait:
            return true
        case .warn:
            guard warn(ActionRegistry.shortcuts(for: event).first?.displayString ?? "⌘Q") else {
                disarm()
                return false
            }
            return true
        }
    }

    /// Whether `event` is a key-down that ran the Quit action from its shortcut: one with
    /// Command held. A menu pick, a palette Return or a scripted run is not.
    public nonisolated static func isShortcutPress(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return event.modifierFlags.contains(.command)
    }

    /// Feeds the shortcut's key-down `event`. `.warn`: show the warning; `.quit`: quit now.
    public func press(_ event: NSEvent) -> QuitShortcutPresses.Outcome {
        press(isRepeat: event.isARepeat, timestamp: event.timestamp, keyCode: event.keyCode, modifiers: Self.chord(event))
    }

    func press(isRepeat: Bool, timestamp: TimeInterval, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> QuitShortcutPresses.Outcome {
        let outcome = presses.press(isRepeat: isRepeat, timestamp: timestamp)
        switch outcome {
        case .warn:
            armedKeyCode = keyCode
            armedModifiers = modifiers
            watchRepeats()
        case .wait:
            break
        case .quit:
            disarm()
        }
        return outcome
    }

    /// Ends the warning and the watch: the next press warns again.
    public func disarm() {
        presses.reset()
        armedKeyCode = nil
        armedModifiers = nil
        if let monitor { removeMonitor(monitor) }
        monitor = nil
        onDisarm?()
    }

    private func watchRepeats() {
        guard monitor == nil else { return }
        // Not `self?.repeated(event) ?? event`: that turns a consumed repeat (nil) back into the event.
        monitor = addMonitor { [weak self] event in
            guard let self else { return event }
            return repeated(event)
        }
    }

    /// A key-down while armed: the held shortcut's repeats are the guard's; every other key passes,
    /// and so does the same key held with other modifiers (⌘⇧Q is not ⌘Q).
    func repeated(_ event: NSEvent) -> NSEvent? {
        let chord = Self.chord(event)
        guard event.isARepeat, event.keyCode == armedKeyCode, chord == armedModifiers, Self.isShortcutPress(event) else { return event }
        if press(isRepeat: true, timestamp: event.timestamp, keyCode: event.keyCode, modifiers: chord) == .quit { onHeldQuit?() }
        return nil
    }

    /// The modifiers that make a shortcut (Caps Lock, Fn and the like do not).
    private nonisolated static func chord(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .shift, .option, .control])
    }
}
