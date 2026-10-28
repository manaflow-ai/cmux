public import AppKit

/// A two-key shortcut (`["ctrl+b", "c"]` in cmux.json), as the old app's
/// Prefix-chord bindings: the first key arms it, the next key runs the action.
/// The first key needs Command or Control, since only those reach the key
/// router; the second may be a plain key.
public nonisolated struct ShortcutChord: Hashable, Sendable {
    public let first: Shortcut
    public let second: Shortcut

    public init(_ first: Shortcut, _ second: Shortcut) {
        self.first = first
        self.second = second
    }

    @MainActor public var keycaps: [String] { first.keycaps + second.keycaps }
}

/// One binding under a chord's first key: the second key and its action.
public nonisolated struct ChordBinding: Hashable, Sendable {
    public let second: Shortcut
    public let id: ActionID

    public init(second: Shortcut, id: ActionID) {
        self.second = second
        self.id = id
    }
}

extension ActionRegistry {
    /// `id`'s chord: from cmux.json (it replaces the single key), else its
    /// default chord (it adds to it; `LeaderLayer.defaultChord(for:)`).
    public func effectiveChord(for id: ActionID) -> ShortcutChord? {
        let id = canonicalID(for: id)
        return chordOverrides[id] ?? LeaderLayer(registry: self).defaultChord(for: id)
    }

    /// Sets a chord override (replacing any single-key override).
    public func setChordOverride(_ chord: ShortcutChord, for id: ActionID) {
        let id = canonicalID(for: id)
        shortcutOverrides.removeValue(forKey: id)
        chordOverrides[id] = chord
    }

    /// The shortcuts a key-down may mean (``shortcuts(for:)-(KeyInput)``), with this registry's
    /// keyboard layout reader for the ASCII fallback.
    /// `armed`: a chord is armed and the key is its next key.
    public func shortcuts(for event: NSEvent, armed: Bool = false) -> ShortcutReadings {
        guard event.type == .keyDown else { return ShortcutReadings() }
        return Self.shortcuts(for: KeyInput(event, layout: keyboardLayout), armed: armed)
    }

    /// The shortcuts a key may mean, in Ghostty's match order (ghostty-next src/input/Binding.zig
    /// `Set.getEvent`), each with the key's modifiers:
    /// 1. the physical key, where bindings are physical: a Command or Control chord on the digit
    ///    row reads its digit on every layout (Ghostty binds `goto_tab` to `digit_N` and to `N`,
    ///    because AZERTY types `&` `é` `"` on those keys);
    /// 2. the text the key types, when it is one character (with Command held, the layout's
    ///    Command map: QWERTY on Russian, Greek or Dvorak - QWERTY ⌘), unless Option is held: an
    ///    Option character (ƒ for Option-F, @ for Option-L on German) names no binding, so an
    ///    Option chord reads its key as before (and the shortcut recorder records Cmd-Opt-F, not ƒ);
    /// 3. with Command held, the Command map's unshifted key (`]` for Cmd-Shift-] on Dvorak - QWERTY ⌘);
    /// 4. AppKit's key-equivalent reading (`charactersIgnoringModifiers`: function keys and the
    ///    layout's own letters), and 5. the unshifted key ("]" for Shift-]), each when one character;
    /// 6. for a Command or Control chord whose key types no ASCII character, the ASCII-capable
    ///    layout's key (Ctrl-B on Russian is the key with the Latin B).
    /// An `armed` key (the next key of an armed chord: Cmd-J then S) is not typing either, so it
    /// takes the digit-row and ASCII-capable readings like a chord.
    /// Letters are never read by position (Cmd-Z on German is the key that types z), and a plain,
    /// Shift or Option key reads only what it types: cmux decides those only after the input
    /// methods, never as a shortcut found by position or by another layout.
    public static func shortcuts(for input: KeyInput, armed: Bool = false) -> ShortcutReadings {
        let flags = input.modifiers
        var readings = ShortcutReadings()
        let decided = input.isChord || armed
        if decided, let digit = Self.digitRow[input.keyCode] { readings.append(Shortcut(digit, modifiers: flags)) }
        // Three calls, not a loop over an array: reading a key allocates no array (p04-input-055).
        func appendTyped(_ typed: String?) {
            if let typed, typed.unicodeScalars.count == 1 { readings.append(Shortcut(typed, modifiers: flags)) }
        }
        if !flags.contains(.option) { appendTyped(input.text) }
        appendTyped(input.commandUnshifted)
        appendTyped(input.ignoringModifiers)
        appendTyped(input.unshifted)
        if decided, let ascii = input.asciiFallback { readings.append(Shortcut(ascii, modifiers: flags)) }
        return readings
    }

    /// The digit each digit-row key names (Ghostty's `digit_1` ... `digit_0`, kVK_ANSI_1 ... kVK_ANSI_0).
    nonisolated static let digitRow: [UInt16: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    ]
}
