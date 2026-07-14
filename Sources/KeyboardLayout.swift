import AppKit
import Carbon

class KeyboardLayout {
    private enum ModifierTranslationMode {
        case shortcut
        case textInput
    }

    /// Test-only override for the current input source ID.
    #if DEBUG
    static var debugInputSourceIdOverride: String?
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
    /// case we fall back to TISCopyCurrentASCIICapableKeyboardInputSource().
    static func character(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let result = characterFromInputSource(
               source,
               forKeyCode: keyCode,
               modifierFlags: modifierFlags,
               mode: .shortcut
           ),
           result.allSatisfy(\.isASCII) {
            return result
        }
        // Current input source has no Unicode layout data or returned a non-ASCII
        // character (e.g. Korean 두벌식 has layout data but UCKeyTranslate still
        // produces Hangul). Fall back to the ASCII-capable source so shortcut
        // matching still works.
        if let asciiSource = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue(),
           let result = characterFromInputSource(
               asciiSource,
               forKeyCode: keyCode,
               modifierFlags: modifierFlags,
               mode: .shortcut
           ) {
            return result
        }
        return nil
    }

    /// Translate a physical keyCode using the current input source exactly as
    /// text input would, including Option/Shift and without ASCII fallback.
    static func textInputCharacter(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return characterFromInputSource(
            source,
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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control), let decoded = controlModifiedBaseCharacter(raw) {
            return decoded
        }
        if raw.allSatisfy(\.isASCII) { return raw }
        if let layoutChar = character(forKeyCode: event.keyCode, modifierFlags: []) {
            return layoutChar
        }
        return raw
    }

    /// Restore a shortcut's logical key after Control has encoded it as a C0 character,
    /// then normalize shifted symbols to the base key stored by the shortcut recorder.
    static func normalizedShortcutCharacter(
        _ eventCharacter: String,
        applyControlCharacterNormalization: Bool,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> String {
        let lowered = eventCharacter.lowercased()
        let logicalKey = applyControlCharacterNormalization
            ? controlModifiedBaseCharacter(lowered) ?? lowered
            : lowered

        switch logicalKey {
        case "+": return "="
        case "_": return "-"
        default: break
        }

        guard applyShiftSymbolNormalization else { return logicalKey }

        switch logicalKey {
        case "{": return "["
        case "}": return "]"
        case "<": return eventKeyCode == 43 ? "," : logicalKey // kVK_ANSI_Comma
        case ">": return eventKeyCode == 47 ? "." : logicalKey // kVK_ANSI_Period
        case "?": return "/"
        case ":": return ";"
        case "\"": return "'"
        case "|": return "\\"
        case "~": return "`"
        case "!": return eventKeyCode == 18 ? "1" : logicalKey // kVK_ANSI_1
        case "@": return eventKeyCode == 19 ? "2" : logicalKey // kVK_ANSI_2
        case "#": return eventKeyCode == 20 ? "3" : logicalKey // kVK_ANSI_3
        case "$": return eventKeyCode == 21 ? "4" : logicalKey // kVK_ANSI_4
        case "%": return eventKeyCode == 23 ? "5" : logicalKey // kVK_ANSI_5
        case "^": return eventKeyCode == 22 ? "6" : logicalKey // kVK_ANSI_6
        case "&": return eventKeyCode == 26 ? "7" : logicalKey // kVK_ANSI_7
        case "*": return eventKeyCode == 28 ? "8" : logicalKey // kVK_ANSI_8
        case "(": return eventKeyCode == 25 ? "9" : logicalKey // kVK_ANSI_9
        case ")": return eventKeyCode == 29 ? "0" : logicalKey // kVK_ANSI_0
        default: return logicalKey
        }
    }

    private static func controlModifiedBaseCharacter(_ characters: String) -> String? {
        guard characters.unicodeScalars.count == 1,
              let scalar = characters.unicodeScalars.first else {
            return nil
        }

        let decodedValue: UInt32
        switch scalar.value {
        case 0x00:
            decodedValue = 0x40 // @
        case 0x01...0x1A:
            decodedValue = scalar.value + 0x60 // a...z
        case 0x1B...0x1F:
            decodedValue = scalar.value + 0x40 // [..._
        case 0x7F:
            decodedValue = 0x3F // ?
        default:
            return nil
        }
        guard let decoded = UnicodeScalar(decodedValue) else { return nil }
        return String(decoded)
    }

    private static func characterFromInputSource(
        _ source: TISInputSource,
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        mode: ModifierTranslationMode,
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

    private static func translationModifierKeyState(
        for modifierFlags: NSEvent.ModifierFlags,
        mode: ModifierTranslationMode
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
