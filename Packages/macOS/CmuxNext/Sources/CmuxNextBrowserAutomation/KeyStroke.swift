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
    /// inserts `text` through the text input client instead). The rules are
    /// Rust's (cmux-browser-rules `input.rs`, op `browser_rules_input_key_stroke`).
    public static func resolve(key: String, code: String, text: String?, modifiers: [String]) -> KeyStroke? {
        let request = Request(key: key, code: code, text: text, modifiers: modifiers)
        // A null reply (no virtual key) and a library that does not answer both read as nil.
        guard let reply = BrowserRulesFFI.input("key_stroke", request, as: Reply?.self) ?? nil else { return nil }
        return KeyStroke(keyCode: reply.keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: reply.modifierFlags),
                         characters: reply.characters, charactersIgnoringModifiers: reply.charactersIgnoringModifiers,
                         isModifier: reply.isModifier, editingCommand: reply.editingCommand)
    }

    private nonisolated struct Request: Encodable {
        let key: String
        let code: String
        let text: String?
        let modifiers: [String]
    }

    private nonisolated struct Reply: Decodable {
        let keyCode: UInt16
        let modifierFlags: UInt
        let characters: String
        let charactersIgnoringModifiers: String
        let isModifier: Bool
        let editingCommand: String?
    }

    /// The flags of the runtime's modifier names (`Shift`, `Control`, `Alt`,
    /// `Meta`), the vocabulary the Rust rules read; other names add none.
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
}
