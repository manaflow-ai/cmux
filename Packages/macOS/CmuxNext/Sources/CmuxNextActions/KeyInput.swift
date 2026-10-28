public import AppKit

/// One key-down as every cmux key reader sees it, built from an `NSEvent`
/// (``ActionRegistry/shortcuts(for:)-(NSEvent)``).
///
/// It is Ghostty's `KeyEvent` (ghostty-next src/input/key.zig:16-55) as its macOS host fills it
/// (macos/Sources/Ghostty/NSEvent+Extension.swift): the physical key, which is the same on every
/// layout; the modifiers; the text the selected layout types; the codepoint the key types with no
/// modifiers. cmux adds AppKit's key-equivalent reading (`charactersIgnoringModifiers`) and, for a
/// key whose layout types no ASCII character (Russian, Greek, Hebrew, Kana), the character the
/// ASCII-capable layout types on the same physical key (Chrome's and AppKit's fallback for
/// Command and Control shortcuts). Tests build one directly, for any layout, without a keyboard.
public nonisolated struct KeyInput: Equatable, Sendable {
    /// The Carbon virtual key code of the physical key (`kVK_*`), the same on every layout.
    public var keyCode: UInt16
    /// Shift, Control, Option and Command (caps lock, fn and the numeric pad flag never match).
    public var modifiers: NSEvent.ModifierFlags
    /// The text the key types, as Ghostty's host reads it (`ghosttyCharacters`): a single control
    /// character is read again without Control (Ghostty encodes Control itself), and a function
    /// key's private-use character is no text. Nil when the key types nothing.
    public var text: String?
    /// AppKit's key-equivalent reading (`charactersIgnoringModifiers`): every modifier but Shift
    /// left out. Function keys keep their private-use character here (shortcuts name arrows by it).
    public var ignoringModifiers: String?
    /// What the key types with no modifier at all (`characters(byApplyingModifiers: [])`), Ghostty's
    /// `unshifted_codepoint`.
    public var unshifted: String?
    /// With Command held, what the key types with Command alone (`characters(byApplyingModifiers:
    /// [.command])`): the layout's Command map unshifted, `]` for Cmd-Shift-] on Dvorak - QWERTY ⌘ or
    /// Russian, where ``unshifted`` is the layout's own `=` or `ъ`. Nil without Command.
    public var commandUnshifted: String?
    /// The character the ASCII-capable layout types on this physical key, unshifted and lowercase,
    /// when ``unshifted`` is not ASCII; nil otherwise. Only chords and an armed chord's next key read
    /// it (``ActionRegistry/shortcuts(for:armed:)-(KeyInput,_)``).
    public var asciiFallback: String?
    /// The punctuation character US ANSI has on this physical key (`[` on the key German types ü
    /// on), when the selected layout types that character on no key without Option: the position
    /// macOS's localized key equivalents and Chrome fall back to for a shortcut the layout moved to
    /// an Option layer. Nil for letters (never by position), for digits (the digit row is read by
    /// position anyway) and when the layout types the character itself (Dvorak types `[`).
    public var positional: String?

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, text: String?, ignoringModifiers: String? = nil,
                unshifted: String? = nil, commandUnshifted: String? = nil, asciiFallback: String? = nil, positional: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Shortcut.relevantModifiers)
        self.text = text
        self.ignoringModifiers = ignoringModifiers
        self.unshifted = unshifted
        self.commandUnshifted = commandUnshifted
        self.asciiFallback = asciiFallback
        self.positional = positional
    }

    /// The punctuation US ANSI has on each physical key (kVK_ANSI_Minus ... kVK_ANSI_Grave).
    public static let usPunctuation: [UInt16: String] = [
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
    ]

    /// The US punctuation `keyCode` names by position on a layout (``positional``), or nil:
    /// - only punctuation the layout types on no key without Option (`layoutTypes` false);
    /// - only on a key that types no plain ASCII character itself (`keyTypes`: its unshifted text,
    ///   nil or empty for a dead key): German ü and the dead ^ keep a position, German + and French $
    ///   do not (Cmd-+ is zoom there, never Cmd-]);
    /// - on an ISO keyboard (`iso`) the key left of 1 is kVK_ISO_Section (10), the US ` key, and
    ///   kVK_ANSI_Grave (50) is the extra key left of Z, which names nothing.
    public static func positionalPunctuation(keyCode: UInt16, keyTypes: String?, iso: Bool, layoutTypes: (String) -> Bool) -> String? {
        // The rule before review 1 of slice 3 (red): any key whose US punctuation the layout does not type.
        guard let us = usPunctuation[keyCode] else { return nil }
        return layoutTypes(us) ? nil : us
    }

    /// The key is a Command or Control chord: the only keys cmux may decide before the input
    /// methods (`interpretKeyEvents`) see them.
    public var isChord: Bool {
        !modifiers.isDisjoint(with: [.command, .control])
    }

    public static func == (lhs: KeyInput, rhs: KeyInput) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers.rawValue == rhs.modifiers.rawValue && lhs.text == rhs.text
            && lhs.ignoringModifiers == rhs.ignoringModifiers && lhs.unshifted == rhs.unshifted && lhs.commandUnshifted == rhs.commandUnshifted
            && lhs.asciiFallback == rhs.asciiFallback && lhs.positional == rhs.positional
    }
}

@MainActor extension KeyInput {
    /// The key-down `event` as cmux reads it. `layout` answers ``asciiFallback`` (a table lookup,
    /// only for a key that types no ASCII) and ``positional``; nil reads neither.
    public init(_ event: NSEvent, layout: KeyboardLayoutKeys?) {
        let flags = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        let unshifted = event.characters(byApplyingModifiers: [])
        var fallback: String?
        if let unshifted, !unshifted.isEmpty, !unshifted.allSatisfy(\.isASCII) {
            fallback = layout?.asciiCharacter(forKeyCode: event.keyCode)
        }
        let commandUnshifted = flags.contains(.command) ? event.characters(byApplyingModifiers: [.command]) : nil
        var positional: String?
        if let layout {
            positional = Self.positionalPunctuation(keyCode: event.keyCode, keyTypes: unshifted, iso: layout.isISO,
                                                    layoutTypes: layout.typesUnshifted)
        }
        self.init(keyCode: event.keyCode, modifiers: flags, text: Self.text(of: event), ignoringModifiers: event.charactersIgnoringModifiers,
                  unshifted: unshifted, commandUnshifted: commandUnshifted, asciiFallback: fallback, positional: positional)
    }

    /// Ghostty's `ghosttyCharacters` (NSEvent+Extension.swift): the event's characters, a lone
    /// control character read again without Control, a lone function-key character dropped.
    nonisolated static func text(of event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        let scalars = characters.unicodeScalars
        if scalars.count == 1, let scalar = scalars.first {
            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }
}
