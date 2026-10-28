public import AppKit

/// A key typed for a terminal whose view is not live yet (the launch picture, p08-startup-061), as the live view would
/// send it, so the key goes to the daemon by the terminal's id at once and no view has to be built for it:
/// - A key that commits text (a letter, a symbol, an Option character, a space) is that text: what Ghostty writes
///   for such a key.
/// - A key Ghostty encodes from the key itself (Return, Tab, Escape, Delete, the arrows, Home, End, the page and
///   function keys, a Control chord, an Option chord while `macos-option-as-alt` makes that Option Alt) goes by its
///   `send-key` name, and the daemon's Ghostty key encoder encodes it with the program's own keyboard modes (cursor
///   keys, the Kitty protocol): the path a TUI's Command chords take (`TerminalKeyEquivalent.sendToProgram`). A
///   chord is named by its key code's ANSI key, as Ghostty reads a Control chord, not by the layout's character.
///
/// Nil keeps the key for the live view: a Command chord (never typing), a key that commits nothing (a dead key), and
/// an Option key while the config has not said what Option is.
public nonisolated enum TypedTerminalInput: Sendable, Equatable {
    /// Text the key commits.
    case text(String)
    /// The key's `send-key` name (`enter`, `ctrl+c`, `shift+tab`, `alt+f`).
    case key(String)

    /// Ghostty's `macos-option-as-alt`: which Option keys are Alt instead of composing characters.
    public enum OptionAsAlt: Sendable, Equatable {
        case off, left, right, both

        /// The config's value (`false`, `true`, `left`, `right`); nil for any other.
        public init?(config: String) {
            switch config {
            case "false": self = .off
            case "true": self = .both
            case "left": self = .left
            case "right": self = .right
            default: return nil
            }
        }
    }

    /// The text the key commits, nil for a key sent by name.
    public var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    /// - Parameter optionAsAlt: the config's `macos-option-as-alt`; nil while it is not read (an Option key then
    ///   stays for the live view).
    public init?(_ event: NSEvent, optionAsAlt: OptionAsAlt?) {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard !flags.contains(.command) else { return nil }
        var chordFlags = flags
        if flags.contains(.option) {
            guard let optionAsAlt else { return nil }
            // The device bit says which Option is down; with none, Ghostty reads the left one.
            let right = event.modifierFlags.rawValue & Self.rightOptionMask != 0
            let isAlt: Bool = switch optionAsAlt {
            case .off: false
            case .both: true
            case .left: !right
            case .right: right
            }
            if !isAlt { chordFlags.remove(.option) }
        }
        if let name = Self.namedKeys[event.keyCode] {
            self = .key(Self.chord(name, chordFlags))
            return
        }
        if !chordFlags.isDisjoint(with: [.control, .option]) {
            guard let name = Self.ansiKeys[event.keyCode] else { return nil }
            self = .key(Self.chord(name, chordFlags))
            return
        }
        // A function key with no name here commits AppKit's private-use character, never text.
        guard let text = event.characters, !text.isEmpty,
              !text.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) || $0.value < 0x20 }) else { return nil }
        self = .text(text)
    }

    /// The inputs of the longest run of `events`, from the first, that go by id as the live view would send them;
    /// the first event that cannot (``init(_:optionAsAlt:)`` is nil, it is a key and keys cannot go `byName`, or an
    /// input method is selected, whose keys only the view's text input can compose) and every one after it stay for
    /// the live view, so none overtakes another.
    public static func sendable(_ events: [NSEvent], optionAsAlt: OptionAsAlt?, inputMethod: Bool, byName: Bool) -> [TypedTerminalInput] {
        guard !inputMethod else { return [] }
        var inputs: [TypedTerminalInput] = []
        for event in events {
            guard let input = TypedTerminalInput(event, optionAsAlt: optionAsAlt), byName || input.text != nil else { break }
            inputs.append(input)
        }
        return inputs
    }

    /// `NX_DEVICERALTKEYMASK`: the right Option key is down.
    private static let rightOptionMask: UInt = 0x40

    /// The `send-key` name of `name` with `flags` held: `ctrl+alt+shift+left`.
    private static func chord(_ name: String, _ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        return (parts + [name]).joined(separator: "+")
    }

    /// Keys by their virtual key code (Carbon's `kVK_`), named as `send-key` reads them
    /// (cmux-tui ghostty-vt `key_input_from_chord`).
    private static let namedKeys: [UInt16: String] = [
        36: "enter", 76: "enter", 48: "tab", 53: "escape", 51: "backspace", 117: "delete", 114: "insert",
        123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10",
        103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20",
    ]

    /// The ANSI keyboard's keys by their virtual key code (Carbon's `kVK_ANSI_`), as `send-key` names a chord's key.
    private static let ansiKeys: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w",
        14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j",
        39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 49: "space", 50: "`",
    ]
}
