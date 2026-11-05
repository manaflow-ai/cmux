public import AppKit

/// A held key as the daemon takes it for a terminal whose view is gone (a terminal far off screen, or another
/// machine's): `text` is written as typed (`send`), `key` is a key chord the daemon encodes with that terminal's own
/// modes (`send-key`: cursor and keypad modes, the Kitty keyboard protocol), as a TUI's Command chords already go.
public enum HeldKeyInput: Equatable, Sendable {
    case text(String)
    case key(String)

    /// The inputs of `events`, in order, consecutive text merged. A key with no daemon name (a key code this table does
    /// not know, typed with Control) is left out; the count of left-out keys is `skipped`. `optionAsAlt`: Ghostty's
    /// `macos-option-as-alt` (`true`, `left`, `right`; anything else: Option types what macOS composed).
    public static func inputs(for events: [NSEvent], optionAsAlt: String?) -> (inputs: [HeldKeyInput], skipped: Int) {
        var inputs: [HeldKeyInput] = [], skipped = 0
        for event in events {
            guard let input = HeldKeyInput(event, optionAsAlt: optionAsAlt) else {
                skipped += 1
                continue
            }
            if case .text(let more) = input, case .text(let earlier)? = inputs.last {
                inputs[inputs.count - 1] = .text(earlier + more)
            } else {
                inputs.append(input)
            }
        }
        return (inputs, skipped)
    }

    /// `event` as the daemon takes it: a named key (Return, an arrow, F5), a chord with Control or Command, or an Option
    /// key that `optionAsAlt` makes Alt (ESC and the base key, as the view's encoder sends) is a `key`; other typing
    /// (Option included when it is not Alt: what macOS composed) is `text`.
    public init?(_ event: NSEvent, optionAsAlt: String?) {
        let flags = event.modifierFlags
        let side = flags.rawValue & (Self.leftOption | Self.rightOption)
        let altKey = flags.contains(.option) && (optionAsAlt == "true" || (optionAsAlt == "left" && side & Self.leftOption != 0)
            || (optionAsAlt == "right" && side & Self.rightOption != 0))
        var mods: [String] = []
        if flags.contains(.command) { mods.append("cmd") }
        if flags.contains(.control) { mods.append("ctrl") }
        if flags.contains(.option) { mods.append("alt") }
        if flags.contains(.shift) { mods.append("shift") }
        if let name = Self.names[event.keyCode] {
            self = .key((mods + [name]).joined(separator: "+"))
            return
        }
        if flags.isDisjoint(with: [.command, .control]), altKey {
            // Alt and the key as typed without Option (Shift kept in the character: `alt+A`).
            guard let base = event.charactersIgnoringModifiers, base.count == 1, base.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 })
            else { return nil }
            self = .key("alt+" + base)
            return
        }
        if flags.isDisjoint(with: [.command, .control]) {
            guard let text = event.characters, !text.isEmpty else { return nil }
            self = .text(text)
            return
        }
        // A chord on a character key: the daemon names it by its unshifted character (`ctrl+c`).
        guard let character = event.charactersIgnoringModifiers?.lowercased(), character.count == 1,
              character.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 }) else { return nil }
        self = .key((mods + [character]).joined(separator: "+"))
    }

    /// The device bits of the left and right Option keys in `NSEvent.ModifierFlags` (IOKit's NX_DEVICELALTKEYMASK and
    /// NX_DEVICERALTKEYMASK).
    private static let leftOption: UInt = 0x20, rightOption: UInt = 0x40

    /// The daemon's names (`key_input_from_chord`) of keys typed by key code.
    private static let names: [UInt16: String] = [
        36: "enter", 76: "enter", 48: "tab", 49: "space", 53: "esc", 51: "backspace", 117: "delete", 114: "insert",
        123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10",
        103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20",
    ]
}
