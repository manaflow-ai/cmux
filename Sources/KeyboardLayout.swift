import AppKit
import Carbon

class KeyboardLayout {
    /// Map physical ANSI number-row keys to decimal digits regardless of the active layout.
    /// This keeps Cmd/Ctrl+digit shortcuts working on layouts like Slovak where the top row
    /// can emit localized symbols or letters instead of ASCII digits.
    static func ansiNumberRowDigit(forKeyCode keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1 // kVK_ANSI_1
        case 19: return 2 // kVK_ANSI_2
        case 20: return 3 // kVK_ANSI_3
        case 21: return 4 // kVK_ANSI_4
        case 23: return 5 // kVK_ANSI_5
        case 22: return 6 // kVK_ANSI_6
        case 26: return 7 // kVK_ANSI_7
        case 28: return 8 // kVK_ANSI_8
        case 25: return 9 // kVK_ANSI_9
        case 29: return 0 // kVK_ANSI_0
        default:
            return nil
        }
    }

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
    static func character(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
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
