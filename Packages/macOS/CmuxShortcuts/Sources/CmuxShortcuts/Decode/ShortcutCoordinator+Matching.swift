public import AppKit

/// The pure `NSEvent`-vs-stroke matching predicates the app's shortcut routing
/// compares a live key event against a configured/stored shortcut.
///
/// ## Why these live on ``ShortcutCoordinator``
///
/// Deciding whether a raw key `NSEvent` satisfies a bound shortcut is a fixed
/// transform over the event (key code, modifier flags, produced characters) and
/// the stroke's value components (its key glyph, modifier flags, optional fixed
/// key code), resolved against the pure ``ShortcutKeyTable`` lookups plus a
/// layout-character provider. None of it reads the app's window, tab, focus, or
/// responder state, so it belongs in the shortcut-decode layer beside the decode
/// transforms the coordinator already owns, not as `private` matchers on the
/// app-target ``AppDelegate`` or as `matches(...)` members on the app-target
/// `ShortcutStroke`/`StoredShortcut`.
///
/// These are instance methods (not a static utility) so the same coordinator the
/// app injects its live Carbon-backed ``ShortcutCoordinator/layoutCharacterProvider``
/// into is the single owner of both the decode and the match seam; tests drive
/// them through a coordinator with a deterministic provider.
///
/// ## Faithful relocation
///
/// Every predicate here is a byte-faithful lift of the corresponding code that
/// lived on the app target: the rich character/key-code fallback ladder from
/// `ShortcutStroke.matches(keyCode:modifierFlags:eventCharacter:layoutCharacterProvider:)`
/// and the `AppDelegate.matchShortcutStroke`/`matchShortcut`/`matchArrowShortcut`/
/// `matchTabShortcut`/`matchDirectionalShortcut` wrappers. The shift-symbol
/// normalization, ANSI-key-code fallback gating, and arrow/tab key-code policies
/// are preserved exactly, since changing any of them changes which physical keys
/// fire which shortcut.
extension ShortcutCoordinator {
    /// The fixed key-code/character lookup tables the matchers resolve against.
    /// Stateless `Sendable` value; one shared instance since the lookups are pure,
    /// `nonisolated` so the pure matchers can read it off the main actor.
    private nonisolated static let keyTable = ShortcutKeyTable()

    /// The deviceIndependent modifier subset used to compare an event's modifiers
    /// against a stroke's, dropping the numericPad/function/capsLock noise bits.
    /// Faithful relocation of `ShortcutStroke.normalizedModifierFlags(from:)`.
    nonisolated static func normalizedModifierFlags(from flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }

    /// Whether the key event satisfies the stroke described by `strokeKey`,
    /// `strokeModifierFlags`, and the optional fixed `strokeKeyCode`.
    ///
    /// `strokeKey` is the stored shortcut key glyph (e.g. `"f"`, `"]"`, `"f3"`,
    /// `"media.mute"`, `"\r"`); `strokeModifierFlags` is the stroke's modifier set;
    /// `strokeKeyCode` is the stroke's recorded physical key code when one was
    /// captured. Faithful relocation of the app-target `ShortcutStroke.matches(event:…)`
    /// entry point (media-key handling, keyDown gate) plus its
    /// `matches(keyCode:modifierFlags:eventCharacter:layoutCharacterProvider:)`
    /// predicate ladder.
    ///
    /// `optionTextBypass` is the app-target Option-printable-text bypass decision,
    /// computed by the caller because its layout translation reads
    /// `KeyboardLayout.textInputCharacter` (text-input mode, no ASCII fallback),
    /// which differs from this coordinator's shortcut-mode
    /// ``ShortcutCoordinator/layoutCharacterProvider``; keeping that decision at
    /// the app seam preserves the exact bypass behavior.
    ///
    /// `layoutCharacterProvider` resolves a key code plus modifier flags to the
    /// character the current layout produces, defaulting to this coordinator's
    /// injected provider so callers that hold the coordinator pass nothing and
    /// nonisolated callers (the app-target `ShortcutStroke.matches` forwarders) pass
    /// the value explicitly. The method is `nonisolated` because it reads no mutable
    /// coordinator state beyond that closure.
    public nonisolated func matchesStroke(
        event: NSEvent,
        strokeKey: String,
        strokeModifierFlags: NSEvent.ModifierFlags,
        strokeKeyCode: UInt16?,
        optionTextBypass: Bool,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String?
    ) -> Bool {
        Self.matchesStroke(
            event: event,
            strokeKey: strokeKey,
            strokeModifierFlags: strokeModifierFlags,
            strokeKeyCode: strokeKeyCode,
            optionTextBypass: optionTextBypass,
            layoutCharacterProvider: layoutCharacterProvider
        )
    }

    /// The `nonisolated static` core of the event-vs-stroke predicate so callers
    /// that hold no coordinator instance (the app-target `ShortcutStroke.matches`
    /// forwarders, which run on the main thread but are declared `nonisolated`)
    /// reach the relocated ladder without constructing a `@MainActor` coordinator
    /// or hopping actors. The matchers read only the pure ``ShortcutKeyTable`` and
    /// the injected `layoutCharacterProvider` closure, never coordinator instance
    /// state, so they need no isolation.
    public nonisolated static func matchesStroke(
        event: NSEvent,
        strokeKey: String,
        strokeModifierFlags: NSEvent.ModifierFlags,
        strokeKeyCode: UInt16?,
        optionTextBypass: Bool,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String?
    ) -> Bool {
        let shortcutKey = strokeKey.lowercased()
        if shortcutKey.hasPrefix("media.") {
            guard let eventMediaKey = Self.keyTable.mediaKey(
                systemDefinedSubtype: event.subtype.rawValue,
                data1: event.data1
            )?.key.lowercased() else {
                return false
            }
            return eventMediaKey == shortcutKey &&
                Self.normalizedModifierFlags(from: event.modifierFlags) == strokeModifierFlags
        }

        guard event.type == .keyDown else { return false }
        if optionTextBypass {
            return false
        }

        return matchesStroke(
            strokeKey: shortcutKey,
            strokeModifierFlags: strokeModifierFlags,
            strokeKeyCode: strokeKeyCode,
            keyCode: Self.recordableKeyCode(from: event) ?? event.keyCode,
            modifierFlags: event.modifierFlags,
            eventCharacter: event.charactersIgnoringModifiers,
            layoutCharacterProvider: layoutCharacterProvider
        )
    }

    /// The character/key-code predicate ladder for a stroke, against an already
    /// extracted `keyCode`/`modifierFlags`/`eventCharacter`. Faithful relocation of
    /// `ShortcutStroke.matches(keyCode:modifierFlags:eventCharacter:layoutCharacterProvider:)`.
    public nonisolated func matchesStroke(
        strokeKey: String,
        strokeModifierFlags: NSEvent.ModifierFlags,
        strokeKeyCode: UInt16?,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventCharacter: String?,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String?
    ) -> Bool {
        Self.matchesStroke(
            strokeKey: strokeKey,
            strokeModifierFlags: strokeModifierFlags,
            strokeKeyCode: strokeKeyCode,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            eventCharacter: eventCharacter,
            layoutCharacterProvider: layoutCharacterProvider
        )
    }

    /// The `nonisolated static` core of the extracted-key-code predicate ladder, so
    /// the nonisolated `ShortcutStroke.matches(keyCode:…)` forwarder reaches it
    /// without a `@MainActor` coordinator instance.
    public nonisolated static func matchesStroke(
        strokeKey: String,
        strokeModifierFlags: NSEvent.ModifierFlags,
        strokeKeyCode: UInt16?,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventCharacter: String?,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String?
    ) -> Bool {
        let flags = Self.normalizedModifierFlags(from: modifierFlags)
        guard flags == strokeModifierFlags else { return false }

        let shortcutKey = strokeKey.lowercased()
        if Self.keyTable.usesDirectKeyCodeMatching(shortcutKey) {
            guard let expectedKeyCode = strokeKeyCode ?? Self.keyTable.keyCodeForShortcutKey(shortcutKey) else {
                return false
            }
            return keyCode == expectedKeyCode
        }

        if shortcutKey == "\r" {
            return keyCode == 36 || keyCode == 76
        }

        if Self.keyTable.shortcutCharacterMatches(
            eventCharacter: eventCharacter,
            shortcutKey: shortcutKey,
            applyShiftSymbolNormalization: flags.contains(.shift),
            eventKeyCode: keyCode
        ) {
            return true
        }

        let hasEventChars = !(eventCharacter?.isEmpty ?? true)
        let eventCharsAreASCII = eventCharacter?.allSatisfy(\.isASCII) ?? true
        let eventCharsArePrintableASCII = eventCharacter?.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && !CharacterSet.controlCharacters.contains(scalar)
        } ?? true
        let shortcutKeyIsDigit = shortcutKey.count == 1 && shortcutKey.first?.isNumber == true
        let shortcutKeyIsLetter = shortcutKey.count == 1 && shortcutKey.first?.isLetter == true
        let eventCharacterIsLetterOrNumber = eventCharacter?.count == 1 &&
            (eventCharacter?.first?.isLetter == true || eventCharacter?.first?.isNumber == true)
        let commandPrintableCharacterShouldBlockFallback = flags.contains(.command) &&
            hasEventChars &&
            eventCharsArePrintableASCII &&
            (!flags.contains(.control) || !shortcutKeyIsLetter) &&
            (shortcutKeyIsLetter || eventCharacterIsLetterOrNumber)
        if shortcutKeyIsDigit,
           hasEventChars,
           eventCharsAreASCII,
           Self.keyTable.digitForNumberKeyCode(keyCode) == nil {
            return false
        }
        if commandPrintableCharacterShouldBlockFallback {
            return false
        }

        let layoutCharacter = layoutCharacterProvider(keyCode, modifierFlags)
        if Self.keyTable.shortcutCharacterMatches(
            eventCharacter: layoutCharacter,
            shortcutKey: shortcutKey,
            applyShiftSymbolNormalization: false,
            eventKeyCode: keyCode
        ) {
            return true
        }

        let allowANSIKeyCodeFallback = flags.contains(.control)
            || (flags.contains(.command)
                && !flags.contains(.control)
                && (
                    !Self.keyTable.shouldRequireCharacterMatchForCommandShortcut(shortcutKey: shortcutKey)
                        || (hasEventChars && !eventCharsAreASCII)
                        || (!hasEventChars && (layoutCharacter?.isEmpty ?? true))
                ))
        if allowANSIKeyCodeFallback,
           let expectedKeyCode = Self.keyTable.keyCodeForShortcutKey(shortcutKey) {
            return keyCode == expectedKeyCode
        }

        return false
    }

    /// The physical key code the recorder would store for `event`, preserving the
    /// exact code for special/media keys, or `nil` when the event is not
    /// recordable. Faithful relocation of the `ShortcutStroke.recordableKey(from:)`
    /// path, returning only the key code (the only field `matches` reads from it).
    private nonisolated static func recordableKeyCode(from event: NSEvent) -> UInt16? {
        if event.type == .systemDefined {
            return keyTable.mediaKey(
                systemDefinedSubtype: event.subtype.rawValue,
                data1: event.data1
            )?.keyCode
        }

        guard event.type == .keyDown || event.type == .keyUp else {
            return nil
        }

        if let specialKey = event.specialKey,
           let recordableKey = keyTable.recordableKey(from: specialKey, eventKeyCode: event.keyCode) {
            return recordableKey.keyCode
        }

        guard keyTable.storedKey(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) != nil else {
            return nil
        }
        return event.keyCode
    }

    /// The numbered-digit (1–9) a number-row shortcut stroke matches for `event`,
    /// gated on the stroke's modifier flags, or `nil`. Faithful relocation of
    /// `AppDelegate.numberedShortcutDigit(event:stroke:)`.
    public func numberedShortcutDigit(
        event: NSEvent,
        strokeModifierFlags: NSEvent.ModifierFlags
    ) -> Int? {
        numberedShortcutDigit(
            eventKeyCode: event.keyCode,
            eventCharactersIgnoringModifiers: event.charactersIgnoringModifiers,
            eventModifierFlags: event.modifierFlags,
            requireModifierFlags: strokeModifierFlags
        )
    }

    /// Whether the event matches an arrow-key stroke, comparing the fixed
    /// `keyCode` and the modifier flags after stripping numericPad/function (which
    /// arrow events always carry). Faithful relocation of
    /// `AppDelegate.matchArrowShortcut(event:stroke:keyCode:)`.
    public func matchesArrowStroke(
        event: NSEvent,
        strokeModifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        return event.keyCode == keyCode && flags == strokeModifierFlags
    }

    /// Whether the event matches a Tab-key stroke (physical key code 48), comparing
    /// the deviceIndependent modifier flags. Faithful relocation of
    /// `AppDelegate.matchTabShortcut(event:stroke:)`.
    public func matchesTabStroke(
        event: NSEvent,
        strokeModifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 48 && flags == strokeModifierFlags
    }

    /// Whether the event matches a directional stroke. When the stroke's key is the
    /// arrow glyph, matches by arrow key code; otherwise falls back to the normal
    /// stroke predicate so users can rebind directional navigation to letter keys.
    /// Faithful relocation of `AppDelegate.matchDirectionalShortcut(event:stroke:arrowGlyph:arrowKeyCode:)`.
    public func matchesDirectionalStroke(
        event: NSEvent,
        strokeKey: String,
        strokeModifierFlags: NSEvent.ModifierFlags,
        strokeKeyCode: UInt16?,
        arrowGlyph: String,
        arrowKeyCode: UInt16,
        optionTextBypass: Bool,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String?
    ) -> Bool {
        if strokeKey == arrowGlyph {
            return matchesArrowStroke(
                event: event,
                strokeModifierFlags: strokeModifierFlags,
                keyCode: arrowKeyCode
            )
        }
        return matchesStroke(
            event: event,
            strokeKey: strokeKey,
            strokeModifierFlags: strokeModifierFlags,
            strokeKeyCode: strokeKeyCode,
            optionTextBypass: optionTextBypass,
            layoutCharacterProvider: layoutCharacterProvider
        )
    }
}
