import AppKit
import Carbon

class KeyboardLayout {
    /// Translate a physical keyCode to the character AppKit would use for shortcut matching,
    /// preserving command-aware layouts. Sources without a directly usable ASCII
    /// character fall back to the system's ASCII-capable shortcut layout.
    static func character(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> String? {
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let result = characterFromInputSource(
               source,
               forKeyCode: keyCode,
               modifierFlags: modifierFlags,
               includeTextModifiers: false
           ),
           result.allSatisfy(\.isASCII) {
            return result.lowercased()
        }
        // Current input source has no Unicode layout data or returned a
        // non-ASCII character. Fall back to the ASCII-capable source so
        // shortcut matching remains independent of the active writing system.
        if let asciiSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let result = characterFromInputSource(
               asciiSource,
               forKeyCode: keyCode,
               modifierFlags: modifierFlags,
               includeTextModifiers: false
           ) {
            return result.lowercased()
        }
        return nil
    }

    /// Recovers printable text when AppKit reports a single C0 payload for a
    /// physical key. AppKit gets the first retry with Control removed; if it
    /// still returns control input, the active keyboard layout resolves the
    /// same physical key and modifiers without classifying a language or key.
    static func recoveredTextForControlCharacterEvent(
        _ event: NSEvent,
        appKitCharacterProvider: (NSEvent, NSEvent.ModifierFlags) -> String? = {
            $0.characters(byApplyingModifiers: $1)
        },
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? =
            KeyboardLayout.textCharacter(forKeyCode:modifierFlags:)
    ) -> String? {
        let modifiersWithoutControl = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.control)

        if let text = appKitCharacterProvider(event, modifiersWithoutControl),
           isPrintableFallbackText(text) {
            return text
        }
        guard let text = layoutCharacterProvider(
            event.keyCode,
            modifiersWithoutControl
        ), isPrintableFallbackText(text) else {
            return nil
        }
        return text
    }

    /// Return the ASCII-normalized equivalent of `event.charactersIgnoringModifiers`,
    /// falling back through the ASCII-capable input source for non-Latin input methods.
    /// Use this wherever code compares raw event characters against Latin shortcut keys.
    static func normalizedCharacters(for event: NSEvent) -> String {
        let raw = (event.charactersIgnoringModifiers ?? "").lowercased()
        if raw.allSatisfy(\.isASCII) { return raw }
        if let layoutChar = character(forKeyCode: event.keyCode, modifierFlags: []) {
            return layoutChar
        }
        return raw
    }

    /// Returns the physical-layout code point libghostty uses for encoding.
    ///
    /// AppKit normally supplies the correct unmodified layout scalar. A Control
    /// combination can instead collapse `characters` to a C0 byte, so only that
    /// ambiguous case uses the ASCII-capable shortcut layout to recover the key.
    static func unshiftedCodepoint(
        for event: NSEvent,
        controlCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? =
            KeyboardLayout.character(forKeyCode:modifierFlags:),
        eventCharacterProvider: (NSEvent) -> String? = {
            $0.characters(byApplyingModifiers: [])
        }
    ) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp else { return 0 }

        if event.modifierFlags.contains(.control),
           isSingleC0ControlText(event.characters),
           let layoutText = controlCharacterProvider(event.keyCode, []),
           let scalar = singlePrintableASCIIScalar(in: layoutText) {
            return scalar.value
        }

        guard let text = eventCharacterProvider(event),
              let scalar = text.unicodeScalars.first else {
            return 0
        }
        return scalar.value
    }

    private static func isSingleC0ControlText(_ text: String?) -> Bool {
        guard let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return false
        }
        return scalar.value < 0x20
    }

    private static func singlePrintableASCIIScalar(in text: String) -> UnicodeScalar? {
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex,
              scalar.value >= 0x20,
              scalar.value < 0x7F else {
            return nil
        }
        return scalar
    }

    private static func characterFromInputSource(
        _ source: TISInputSource,
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        includeTextModifiers: Bool
    ) -> String? {
        guard let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let keyboardLayout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0

        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            carbonModifierKeyState(
                for: modifierFlags,
                includeTextModifiers: includeTextModifiers
            ),
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    private static func textCharacter(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> String? {
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let result = characterFromInputSource(
               source,
               forKeyCode: keyCode,
               modifierFlags: modifierFlags,
               includeTextModifiers: true
           ) {
            return result
        }
        if let asciiSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            return characterFromInputSource(
                asciiSource,
                forKeyCode: keyCode,
                modifierFlags: modifierFlags,
                includeTextModifiers: true
            )
        }
        return nil
    }

    private static func isPrintableFallbackText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return true
        }
        return scalar.value >= 0x20 &&
            !(scalar.value >= 0xF700 && scalar.value <= 0xF8FF)
    }

    private static func carbonModifierKeyState(
        for modifierFlags: NSEvent.ModifierFlags,
        includeTextModifiers: Bool
    ) -> UInt32 {
        var supportedFlags: NSEvent.ModifierFlags = [.shift, .command]
        if includeTextModifiers {
            supportedFlags.formUnion([.option, .capsLock])
        }
        let normalized = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(supportedFlags)

        var carbonModifiers: Int = 0
        if normalized.contains(.shift) {
            carbonModifiers |= shiftKey
        }
        if normalized.contains(.option) {
            carbonModifiers |= optionKey
        }
        if normalized.contains(.command) {
            carbonModifiers |= cmdKey
        }
        if normalized.contains(.capsLock) {
            carbonModifiers |= alphaLock
        }
        return UInt32((carbonModifiers >> 8) & 0xFF)
    }
}
