import AppKit

/// A key press on the Chief's screen, as the computer's input (`HomeChiefComputerInput`): text the
/// person types goes as `type`, any other key or a chord as an xdotool key name (`ctrl+l`, `Return`).
/// The computer runs Linux, so Command stands for Control there (Command-C copies, as on the Mac).
enum HomeChiefComputerKeys {
    /// macOS virtual key codes of the keys that are names, not text.
    static let named: [UInt16: String] = [
        36: "Return", 76: "Return", 48: "Tab", 51: "BackSpace", 117: "Delete", 53: "Escape",
        123: "Left", 124: "Right", 125: "Down", 126: "Up", 115: "Home", 119: "End", 116: "Prior", 121: "Next",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12",
    ]

    /// Punctuation keys by the character they type without Shift, as keysym names.
    static let punctuation: [Character: String] = [
        "-": "minus", "=": "equal", ",": "comma", ".": "period", "/": "slash", ";": "semicolon",
        "'": "apostrophe", "[": "bracketleft", "]": "bracketright", "\\": "backslash", "`": "grave", " ": "space",
    ]

    /// The input for one key press; nil for a key the computer has no name for (a bare modifier).
    /// - Parameters:
    ///   - characters: what the key typed (`NSEvent.characters`), Shift applied.
    ///   - bare: the key's character without modifiers (`charactersIgnoringModifiers`).
    static func input(keyCode: UInt16, characters: String?, bare: String?, modifiers: NSEvent.ModifierFlags) -> HomeChiefComputerInput? {
        var chord: [String] = []
        if modifiers.contains(.control) || modifiers.contains(.command) { chord.append("ctrl") }
        if modifiers.contains(.option) { chord.append("alt") }
        let named = Self.named[keyCode]
        if chord.isEmpty, named == nil {
            guard let characters, !characters.isEmpty, characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            return .type(characters)
        }
        if modifiers.contains(.shift) { chord.append("shift") }
        guard let key = named ?? bare?.lowercased().first.flatMap(Self.keyName) else { return nil }
        return .key((chord + [key]).joined(separator: "+"))
    }

    private static func keyName(_ character: Character) -> String? {
        if character.isASCII, character.isLetter || character.isNumber { return String(character) }
        return punctuation[character]
    }
}
