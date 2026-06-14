import AppKit
import Carbon

class KeyboardLayout {
    /// Test-only override for the current input source ID.
    #if DEBUG
    static var debugInputSourceIdOverride: String?
    static var debugCharacterForInputSourceKind: ((InputSourceKind, UInt16, NSEvent.ModifierFlags, TranslationMode, Bool) -> String?)?
    #endif

    /// Return a string ID of the current keyboard input source.
    static var id: String? {
        #if DEBUG
        if let override = debugInputSourceIdOverride { return override }
        #endif
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let sourceIdPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let sourceId = Unmanaged<CFString>.fromOpaque(sourceIdPointer).takeUnretainedValue()
            return sourceId as String
        }

        return nil
    }

    /// Translate a physical keyCode to the character AppKit would use for shortcut matching,
    /// preserving command-aware layouts such as "Dvorak - QWERTY Command".
    /// Some CJK input sources lack kTISPropertyUnicodeKeyLayoutData, and others (Korean
    /// 두벌식) have it but UCKeyTranslate still returns non-ASCII characters. In either
    /// case we ask the current keyboard layout input source before falling back to
    /// TISCopyCurrentASCIICapableKeyboardInputSource().
    static func character(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> String? {
        let sourceKinds: [InputSourceKind] = [
            .currentKeyboardInputSource,
            .currentKeyboardLayoutInputSource,
            .currentASCIICapableKeyboardInputSource,
        ]

        for sourceKind in sourceKinds {
            if let result = character(
                from: sourceKind,
                forKeyCode: keyCode,
                modifierFlags: modifierFlags,
                mode: .shortcut
            ),
               !result.isEmpty,
               result.allSatisfy(\.isASCII) {
                return result
            }
        }
        return nil
    }

    /// Translate a physical keyCode through the user's ASCII-capable keyboard source.
    /// Terminal copy-mode vim keys use this for physical h/j/k/l fallback when an IME
    /// reports non-ASCII characters; app shortcut matching should use `character`.
    static func asciiCapableCharacter(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> String? {
        guard let result = character(
            from: .currentASCIICapableKeyboardInputSource,
            forKeyCode: keyCode,
            modifierFlags: modifierFlags,
            mode: .shortcut
        ),
              !result.isEmpty,
              result.allSatisfy(\.isASCII) else {
            return nil
        }
        return result
    }

    /// Translate a physical keyCode using the current input source exactly as
    /// text input would, including Option/Shift and without ASCII fallback.
    static func textInputCharacter(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> String? {
        character(
            from: .currentKeyboardInputSource,
            forKeyCode: keyCode,
            modifierFlags: modifierFlags,
            mode: .textInput,
            lowercased: false
        )
    }

    #if DEBUG
    /// Translate a physical keyCode against a specific keyboard input source
    /// exactly as text input would (Option/Shift applied, no ASCII fallback).
    /// Resolves the source from all installed input sources, so layouts that
    /// are not enabled on the host (e.g. German on a US machine) still
    /// translate. Test-only seam for Option-composition regression coverage.
    static func textInputCharacter(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        inputSourceID: String
    ) -> String? {
        guard let source = installedInputSource(forID: inputSourceID) else { return nil }
        return characterFromInputSource(
            source,
            forKeyCode: keyCode,
            modifierFlags: modifierFlags,
            mode: .textInput,
            lowercased: false
        )
    }

    private static func installedInputSource(forID inputSourceID: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return list.first
    }
    #endif

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

    private static func characterFromInputSource(
        _ source: TISInputSource,
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        mode: TranslationMode,
        lowercased: Bool = true
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
            translationModifierKeyState(for: modifierFlags, mode: mode),
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return nil }
        let result = String(utf16CodeUnits: chars, count: length)
        return lowercased ? result.lowercased() : result
    }

    private static func character(
        from sourceKind: InputSourceKind,
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        mode: TranslationMode,
        lowercased: Bool = true
    ) -> String? {
        #if DEBUG
        if let debugCharacterForInputSourceKind,
           let result = debugCharacterForInputSourceKind(sourceKind, keyCode, modifierFlags, mode, lowercased) {
            return lowercased ? result.lowercased() : result
        }
        #endif

        guard let source = inputSource(for: sourceKind) else {
            return nil
        }
        return characterFromInputSource(
            source,
            forKeyCode: keyCode,
            modifierFlags: modifierFlags,
            mode: mode,
            lowercased: lowercased
        )
    }

    private static func inputSource(for sourceKind: InputSourceKind) -> TISInputSource? {
        switch sourceKind {
        case .currentKeyboardInputSource:
            return TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        case .currentKeyboardLayoutInputSource:
            return TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        case .currentASCIICapableKeyboardInputSource:
            return TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue()
        }
    }

    private static func translationModifierKeyState(
        for modifierFlags: NSEvent.ModifierFlags,
        mode: TranslationMode
    ) -> UInt32 {
        let translatedModifiers: NSEvent.ModifierFlags = {
            switch mode {
            case .shortcut:
                return [.shift, .command]
            case .textInput:
                return [.shift, .option]
            }
        }()
        let normalized = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(translatedModifiers)

        var carbonModifiers: Int = 0
        if normalized.contains(.shift) {
            carbonModifiers |= shiftKey
        }
        if normalized.contains(.command) {
            carbonModifiers |= cmdKey
        }
        if normalized.contains(.option) {
            carbonModifiers |= optionKey
        }

        return UInt32((carbonModifiers >> 8) & 0xFF)
    }
}
