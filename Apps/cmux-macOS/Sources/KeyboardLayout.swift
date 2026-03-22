import AppKit
import Carbon

class KeyboardLayout {
    /// Return a string ID of the current keyboard input source.
    static var id: String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let sourceIdPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let sourceId = Unmanaged<CFString>.fromOpaque(sourceIdPointer).takeUnretainedValue()
            return sourceId as String
        }

        return nil
    }

    /// Translate a physical keyCode to the character AppKit would use for shortcut matching,
    /// preserving command-aware layouts such as "Dvorak - QWERTY Command".
    /// CJK input sources (Korean, Chinese, Japanese) lack kTISPropertyUnicodeKeyLayoutData,
    /// so we fall back to TISCopyCurrentASCIICapableKeyboardInputSource() in that case.
    static func character(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let result = characterFromInputSource(source, forKeyCode: keyCode, modifierFlags: modifierFlags) {
            return result
        }
        // Current input source has no Unicode layout data (e.g. Korean, Chinese, Japanese IME).
        // Fall back to the ASCII-capable source so shortcut matching still works.
        if let asciiSource = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue(),
           let result = characterFromInputSource(asciiSource, forKeyCode: keyCode, modifierFlags: modifierFlags) {
            return result
        }
        return nil
    }

    private static func characterFromInputSource(
        _ source: TISInputSource,
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
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
            translationModifierKeyState(for: modifierFlags),
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).lowercased()
    }

    private static func translationModifierKeyState(for modifierFlags: NSEvent.ModifierFlags) -> UInt32 {
        let normalized = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.shift, .command])

        var carbonModifiers: Int = 0
        if normalized.contains(.shift) {
            carbonModifiers |= shiftKey
        }
        if normalized.contains(.command) {
            carbonModifiers |= cmdKey
        }

        return UInt32((carbonModifiers >> 8) & 0xFF)
    }
}
