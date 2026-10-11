public import AppKit

/// One native key event for a driver `input.key` call. WebKit treats a key as
/// trusted only when it arrives as an AppKit event, so the runtime's
/// Playwright description (`key`, `code`, `text`, modifiers) becomes the
/// virtual key code, flags and characters of that event.
public nonisolated struct KeyStroke: Hashable, Sendable {
    public let keyCode: UInt16
    public let modifierFlags: NSEvent.ModifierFlags
    /// Characters the event carries (empty for modifier keys).
    public let characters: String
    public let charactersIgnoringModifiers: String
    /// Set for Shift, Control, Alt, Meta and CapsLock: the event is `.flagsChanged`.
    public let isModifier: Bool
    /// A Cocoa editing selector for Meta shortcuts (`selectAll:`): AppKit
    /// routes Command keys as menu equivalents, so WebKit's text path needs
    /// the command sent explicitly, as Playwright's WebKit driver does.
    public let editingCommand: String?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifierFlags.rawValue == rhs.modifierFlags.rawValue
            && lhs.characters == rhs.characters && lhs.charactersIgnoringModifiers == rhs.charactersIgnoringModifiers
            && lhs.isModifier == rhs.isModifier && lhs.editingCommand == rhs.editingCommand
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifierFlags.rawValue)
        hasher.combine(characters)
    }

    /// Resolves a key; `nil` when it has no macOS virtual key (the caller
    /// inserts `text` through the text input client instead).
    public static func resolve(key: String, code: String, text: String?, modifiers: [String]) -> KeyStroke? {
        let code = code.isEmpty ? DOMKeyCodes.code(forKey: key) ?? "" : code
        guard let keyCode = DOMKeyCodes.virtualKey[code] else { return nil }
        var flags = flags(named: modifiers)
        if let modifier = DOMKeyCodes.modifierFlag[code] {
            return KeyStroke(keyCode: keyCode, modifierFlags: flags.union(modifier), characters: "",
                             charactersIgnoringModifiers: "", isModifier: true, editingCommand: nil)
        }
        let named = DOMKeyCodes.namedCharacters[key]
        let ignoring = named ?? Self.base(code: code, key: key)
        // Key-up carries no text from the runtime; the event still needs the
        // key's characters so keyup reports the same key as keydown.
        var characters = named ?? text ?? (key.count == 1 ? key : "")
        if DOMKeyCodes.needsShift(key) { flags.insert(.shift) }
        if flags.contains(.control), let scalar = ignoring.unicodeScalars.first, ignoring.unicodeScalars.count == 1,
           (97...122).contains(scalar.value), let control = UnicodeScalar(scalar.value - 96) {
            characters = String(Character(control))
        } else if flags.contains(.command) {
            characters = ignoring
        }
        if DOMKeyCodes.functionKeys.contains(code) { flags.insert(.function) }
        if DOMKeyCodes.numericPad.contains(code) { flags.insert(.numericPad) }
        let command = flags.contains(.command) ? DOMKeyCodes.editingCommands[ignoring.lowercased()] : nil
        return KeyStroke(keyCode: keyCode, modifierFlags: flags, characters: characters,
                         charactersIgnoringModifiers: ignoring, isModifier: false,
                         editingCommand: flags.contains(.shift) && command == "undo:" ? "redo:" : command)
    }

    static func flags(named names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name {
            case "Shift": flags.insert(.shift)
            case "Control": flags.insert(.control)
            case "Alt": flags.insert(.option)
            case "Meta": flags.insert(.command)
            default: break
            }
        }
        return flags
    }

    /// The unshifted character of a printable key on a US layout.
    private static func base(code: String, key: String) -> String {
        if code.hasPrefix("Key"), code.count == 4 { return code.suffix(1).lowercased() }
        if code.hasPrefix("Digit"), code.count == 6 { return String(code.suffix(1)) }
        if let symbol = DOMKeyCodes.unshiftedSymbol[code] { return symbol }
        return key.count == 1 ? key.lowercased() : ""
    }
}
