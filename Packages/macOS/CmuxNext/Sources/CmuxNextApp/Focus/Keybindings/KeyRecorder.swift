import AppKit
import CmuxNextActions

/// Records a key sequence for the Keyboard Shortcuts page (R59 "record
/// keys"): the key dispatcher hands it every key-down of the page's window
/// while it records, so the page never reads key events itself. Each stroke
/// is reported; Return or the fourth stroke ends the recording, Escape
/// cancels it. Pure, so tests drive it with shortcuts.
struct KeyRecorder: Equatable {
    struct Event: Equatable {
        var keys: [Shortcut]
        var done: Bool
        var cancelled: Bool
    }

    private(set) var keys: [Shortcut] = []
    private(set) var isFinished = false

    /// The event for one key-down: `shortcut` is the stroke (nil for a key
    /// with no reading), `isEscape` / `isReturn` for an unmodified Escape or
    /// Return.
    mutating func record(_ shortcut: Shortcut?, isEscape: Bool, isReturn: Bool) -> Event? {
        guard !isFinished else { return nil }
        if isEscape {
            isFinished = true
            return Event(keys: keys, done: false, cancelled: true)
        }
        if isReturn, !keys.isEmpty {
            isFinished = true
            return Event(keys: keys, done: true, cancelled: false)
        }
        // Keypad Enter reads as U+0003: a bare Return on either key is one Return stroke, so the
        // page closes the recorder on it as on Return.
        guard let shortcut = isReturn ? Shortcut(Shortcut.returnKey, modifiers: []) : shortcut else { return nil }
        keys.append(shortcut)
        isFinished = keys.count == KeyBindingTable.maxSequenceLength
        return Event(keys: keys, done: isFinished, cancelled: false)
    }

    /// The stroke a key-down records: its first reading (as the dispatcher
    /// matches it), or nil for a bare modifier.
    static func stroke(for event: NSEvent) -> Shortcut? {
        ActionRegistry.shortcuts(for: event).first { !$0.key.isEmpty }
    }

    /// The glyphs of the held modifiers in the menu order (⌃⌥⇧⌘), as a stroke's display writes them.
    static func heldGlyphs(_ flags: NSEvent.ModifierFlags) -> String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }.map(\.1).joined()
    }

    static func isEscape(_ event: NSEvent) -> Bool {
        event.keyCode == ChordTracker.escapeKeyCode && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    static func isReturn(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }
}
