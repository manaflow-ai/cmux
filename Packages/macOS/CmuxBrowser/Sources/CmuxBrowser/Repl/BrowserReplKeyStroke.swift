public import AppKit

/// One native key event resolved from a REPL driver `input.key` call.
///
/// The REPL runtime speaks Playwright's keyboard vocabulary (`key`, `code`,
/// `text`, and `Alt`/`Control`/`Meta`/`Shift` modifiers). WebKit only treats
/// a key as trusted when it arrives as an AppKit event, so this resolves the
/// Playwright description into the virtual key code, flags and characters of
/// that event.
public struct BrowserReplKeyStroke: Equatable, Sendable {
    /// macOS virtual key code.
    public let keyCode: UInt16
    /// Modifier flags carried by the event, including intrinsic Shift.
    public let modifierFlags: NSEvent.ModifierFlags
    /// Characters attached to the event (empty for modifier keys).
    public let characters: String
    /// Characters produced with modifiers ignored.
    public let charactersIgnoringModifiers: String
    /// The modifier this key toggles, for Shift/Control/Alt/Meta/CapsLock keys.
    public let modifierKey: BrowserKeyboardNativeModifiers?
    /// DOM `KeyboardEvent.location`.
    public let location: Int
    /// A Cocoa editing action to run after key-down. Command shortcuts are
    /// menu key equivalents in AppKit, so WebKit's text input path never sees
    /// them; Playwright's WebKit driver sends the same commands explicitly.
    public let editingCommand: String?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyCode == rhs.keyCode
            && lhs.modifierFlags.rawValue == rhs.modifierFlags.rawValue
            && lhs.characters == rhs.characters
            && lhs.charactersIgnoringModifiers == rhs.charactersIgnoringModifiers
            && lhs.modifierKey == rhs.modifierKey
            && lhs.location == rhs.location
            && lhs.editingCommand == rhs.editingCommand
    }

    /// Resolves a driver key description.
    /// - Parameters:
    ///   - key: `KeyboardEvent.key` (for example `"a"`, `"A"`, `"Enter"`).
    ///   - code: `KeyboardEvent.code` (for example `"KeyA"`); may be empty.
    ///   - text: Text the key inserts, when the runtime computed one.
    ///   - modifiers: Held modifiers named `Alt`, `Control`, `Meta`, `Shift`.
    /// - Returns: `nil` when the key has no macOS virtual key; callers insert
    ///   `text` through the text input client instead.
    public static func resolve(
        key: String,
        code: String,
        text: String?,
        modifiers: [String]
    ) -> BrowserReplKeyStroke? {
        let event: BrowserKeyboardEvent?
        if !code.isEmpty {
            event = BrowserKeyboardEvent(key: key, code: code, legacyKeyCode: 0)
        } else {
            event = BrowserKeyboardEvent(rawKey: key)
        }
        guard let event, let native = event.nativeKey else { return nil }

        var flags = SyntheticKeyEventFactory.appKitModifierFlags(for: native.modifiers)
        let held = modifierFlags(named: modifiers)
        flags.formUnion(held)

        if let modifierKey = native.modifierKey {
            return BrowserReplKeyStroke(
                keyCode: native.keyCode,
                modifierFlags: flags,
                characters: "",
                charactersIgnoringModifiers: "",
                modifierKey: modifierKey,
                location: native.location,
                editingCommand: nil
            )
        }

        let ignoring = native.charactersIgnoringModifiers ?? ""
        var characters = native.characters ?? ""
        if let text, !text.isEmpty, isPrintable(ignoring) {
            characters = text
        }
        // Playwright inserts no text while Alt is held; without this the
        // event would carry the base letter and WebKit would type it.
        if text == nil, flags.contains(.option), !flags.contains(.command), !flags.contains(.control), isPrintable(ignoring) {
            characters = ""
        }
        if flags.contains(.control),
           let scalar = ignoring.unicodeScalars.first,
           ignoring.unicodeScalars.count == 1,
           scalar.value >= 97, scalar.value <= 122,
           let control = UnicodeScalar(scalar.value - 96) {
            characters = String(control)
        }

        return BrowserReplKeyStroke(
            keyCode: native.keyCode,
            modifierFlags: flags,
            characters: characters,
            charactersIgnoringModifiers: ignoring,
            modifierKey: nil,
            location: native.location,
            editingCommand: editingCommand(code: event.code, key: event.key, flags: flags)
        )
    }

    /// Maps Playwright modifier names to AppKit flags. Unknown names are ignored.
    public static func modifierFlags(named names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name {
            case "Alt": flags.insert(.option)
            case "Control": flags.insert(.control)
            case "Meta": flags.insert(.command)
            case "Shift": flags.insert(.shift)
            default: break
            }
        }
        return flags
    }

    private static func isPrintable(_ string: String) -> Bool {
        guard let scalar = string.unicodeScalars.first, string.unicodeScalars.count == 1 else {
            return false
        }
        return scalar.value >= 0x20 && scalar.value < 0x7F
    }

    static func editingCommand(
        code: String,
        key: String,
        flags: NSEvent.ModifierFlags
    ) -> String? {
        let significant = flags.intersection([.command, .control, .option, .shift])
        guard significant.contains(.command), !significant.contains(.control), !significant.contains(.option) else {
            return nil
        }
        let letter: String
        if code.hasPrefix("Key"), code.count == 4 {
            letter = String(code.suffix(1)).lowercased()
        } else {
            letter = key.lowercased()
        }
        let shifted = significant.contains(.shift)
        switch (letter, shifted) {
        case ("a", false): return "selectAll:"
        case ("c", false): return "copy:"
        case ("x", false): return "cut:"
        case ("v", false): return "paste:"
        case ("z", false): return "undo:"
        case ("z", true): return "redo:"
        // Rich-text shortcuts Chrome's editor handles; WebKit leaves them to
        // an app's Format menu, which a driven pane may not have.
        case ("b", false): return "bold"
        case ("i", false): return "italic"
        case ("u", false): return "underline"
        default: return nil
        }
    }
}
