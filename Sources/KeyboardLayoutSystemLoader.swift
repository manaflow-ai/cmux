import AppKit
import Carbon
import Foundation

struct KeyboardLayoutSystemLoader: Sendable {
    private let inputSourceReader: any KeyboardInputSourceReading
    private let keyCodes: [UInt16]
    private let shortcutModifierFlags: [NSEvent.ModifierFlags]
    private let textInputModifierFlags: [NSEvent.ModifierFlags]

    init(
        inputSourceReader: any KeyboardInputSourceReading,
        keyCodes: [UInt16] = Array(UInt16(0)...UInt16(127)),
        shortcutModifierFlags: [NSEvent.ModifierFlags] = [
            [], .shift, .command, [.shift, .command],
        ],
        textInputModifierFlags: [NSEvent.ModifierFlags] = [
            [], .shift, .option, [.shift, .option],
        ]
    ) {
        self.inputSourceReader = inputSourceReader
        self.keyCodes = keyCodes
        self.shortcutModifierFlags = shortcutModifierFlags
        self.textInputModifierFlags = textInputModifierFlags
    }

    func loadCurrentSnapshot() -> KeyboardLayoutSnapshot? {
        guard let currentSource = inputSourceReader.currentInputSource() else {
            return nil
        }
        let asciiSource = inputSourceReader.currentASCIICapableInputSource()
        let currentShortcutCharacters = translatedCharacters(
            from: currentSource,
            modifierFlags: shortcutModifierFlags,
            mode: .shortcut,
            lowercased: true
        )
        let asciiShortcutCharacters = asciiSource.map {
            translatedCharacters(
                from: $0,
                modifierFlags: shortcutModifierFlags,
                mode: .shortcut,
                lowercased: true
            )
        } ?? [:]
        var shortcutCharacters: [KeyboardLayoutSnapshot.Key: String] = [:]
        for modifierFlags in shortcutModifierFlags {
            for keyCode in keyCodes {
                let key = KeyboardLayoutSnapshot.Key(
                    keyCode: keyCode,
                    modifierFlags: modifierFlags
                )
                if let current = currentShortcutCharacters[key],
                   current.allSatisfy(\.isASCII) {
                    shortcutCharacters[key] = current
                } else if let ascii = asciiShortcutCharacters[key] {
                    shortcutCharacters[key] = ascii
                }
            }
        }

        let textInputCharacters = translatedCharacters(
            from: currentSource,
            modifierFlags: textInputModifierFlags,
            mode: .textInput,
            lowercased: false
        )
        return KeyboardLayoutSnapshot(
            inputSourceID: inputSourceID(from: currentSource),
            shortcutCharacters: shortcutCharacters,
            textInputCharacters: textInputCharacters
        )
    }

    private func inputSourceID(from source: TISInputSource) -> String? {
        guard let sourceIDPointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceID
        ) else {
            return nil
        }
        return Unmanaged<CFString>
            .fromOpaque(sourceIDPointer)
            .takeUnretainedValue() as String
    }

    private func translatedCharacters(
        from source: TISInputSource,
        modifierFlags: [NSEvent.ModifierFlags],
        mode: KeyboardLayoutModifierTranslationMode,
        lowercased: Bool
    ) -> [KeyboardLayoutSnapshot.Key: String] {
        guard let layoutDataPointer = TISGetInputSourceProperty(
            source,
            kTISPropertyUnicodeKeyLayoutData
        ) else {
            return [:]
        }
        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return [:] }
        let keyboardLayout = UnsafeRawPointer(bytes)
            .assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())
        var result: [KeyboardLayoutSnapshot.Key: String] = [:]
        for flags in modifierFlags {
            for keyCode in keyCodes {
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                // Carbon imports UniCharCount as Swift.Int on current SDKs.
                var length: Int = 0
                let status = UCKeyTranslate(
                    keyboardLayout,
                    keyCode,
                    UInt16(kUCKeyActionDisplay),
                    translationModifierKeyState(for: flags, mode: mode),
                    keyboardType,
                    UInt32(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr, length > 0 else { continue }
                let translated = String(utf16CodeUnits: characters, count: length)
                result[KeyboardLayoutSnapshot.Key(
                    keyCode: keyCode,
                    modifierFlags: flags
                )] = lowercased ? translated.lowercased() : translated
            }
        }
        return result
    }

    private func translationModifierKeyState(
        for modifierFlags: NSEvent.ModifierFlags,
        mode: KeyboardLayoutModifierTranslationMode
    ) -> UInt32 {
        let translatedModifiers: NSEvent.ModifierFlags
        switch mode {
        case .shortcut:
            translatedModifiers = [.shift, .command]
        case .textInput:
            translatedModifiers = [.shift, .option]
        }
        let normalized = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(translatedModifiers)
        var carbonModifiers = 0
        if normalized.contains(.shift) { carbonModifiers |= shiftKey }
        if normalized.contains(.command) { carbonModifiers |= cmdKey }
        if normalized.contains(.option) { carbonModifiers |= optionKey }
        return UInt32((carbonModifiers >> 8) & 0xFF)
    }
}
