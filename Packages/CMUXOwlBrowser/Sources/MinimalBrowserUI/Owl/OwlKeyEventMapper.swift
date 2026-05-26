import AppKit
import OwlMojoBindingsGenerated

enum OwlKeyEventMapper {
    static func keyEvent(from event: NSEvent, keyDown: Bool) -> OwlFreshKeyEvent? {
        let keyCode = windowsKeyCode(forMacVirtualKeyCode: event.keyCode)
        guard keyCode != 0 else {
            return nil
        }
        return OwlFreshKeyEvent(
            keyDown: keyDown,
            keyCode: keyCode,
            text: text(for: event, keyDown: keyDown),
            modifiers: cocoaModifiers(from: event.modifierFlags),
            editCommands: OwlKeyEditCommandMapper.editCommands(
                keyDown: keyDown,
                keyCode: keyCode,
                modifiers: cocoaModifiers(from: event.modifierFlags)
            ),
            nativeEventType: UInt32(truncatingIfNeeded: event.type.rawValue),
            nativeKeyCode: UInt32(event.keyCode),
            isRepeat: event.isARepeat,
            characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? ""
        )
    }

    static func modifierEvent(from event: NSEvent) -> OwlFreshKeyEvent? {
        let keyCode = windowsKeyCode(forMacVirtualKeyCode: event.keyCode)
        guard keyCode != 0 else {
            return nil
        }
        return OwlFreshKeyEvent(
            keyDown: modifierIsDown(forMacVirtualKeyCode: event.keyCode, flags: event.modifierFlags),
            keyCode: keyCode,
            text: "",
            modifiers: cocoaModifiers(from: event.modifierFlags),
            editCommands: [],
            nativeEventType: UInt32(truncatingIfNeeded: event.type.rawValue),
            nativeKeyCode: UInt32(event.keyCode),
            isRepeat: false,
            characters: "",
            charactersIgnoringModifiers: ""
        )
    }

    static func shouldForwardToWebContentAsKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control) else {
            return false
        }

        let keyCode = windowsKeyCode(forMacVirtualKeyCode: event.keyCode)
        if browserChromeShortcutKeyCodes.contains(keyCode) {
            return false
        }
        if webEditingShortcutKeyCodes.contains(keyCode) {
            return true
        }
        if webEditingNavigationKeyCodes.contains(keyCode) {
            return true
        }
        return false
    }

    static func windowsKeyCode(forMacVirtualKeyCode keyCode: UInt16) -> UInt32 {
        guard Int(keyCode) < windowsKeyCodesByMacVirtualKeyCode.count else {
            return 0
        }
        return windowsKeyCodesByMacVirtualKeyCode[Int(keyCode)]
    }

    static func cocoaModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        UInt32(truncatingIfNeeded: flags.intersection(.deviceIndependentFlagsMask).rawValue)
    }

    private static func text(for event: NSEvent, keyDown: Bool) -> String {
        guard keyDown,
              textProducingMacVirtualKeyCodes.contains(event.keyCode),
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control) else {
            return ""
        }
        return event.characters ?? ""
    }

    private static func modifierIsDown(
        forMacVirtualKeyCode keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) -> Bool {
        switch keyCode {
        case 54, 55:
            return flags.contains(.command)
        case 56, 60:
            return flags.contains(.shift)
        case 58, 61:
            return flags.contains(.option)
        case 59, 62:
            return flags.contains(.control)
        case 57:
            return flags.contains(.capsLock)
        default:
            return false
        }
    }

    private static let browserChromeShortcutKeyCodes: Set<UInt32> = [
        49, 50, 51, 52, 53, 54, 55, 56, 57,
        73, 74, 75, 76, 82, 84, 87,
        219, 221
    ]

    private static let webEditingShortcutKeyCodes: Set<UInt32> = [
        65, 67, 86, 88, 90
    ]

    private static let webEditingNavigationKeyCodes: Set<UInt32> = [
        8, 33, 34, 35, 36, 37, 38, 39, 40, 46
    ]

    private static let textProducingMacVirtualKeyCodes: Set<UInt16> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
        10, 11, 12, 13, 14, 15, 16, 17,
        18, 19, 20, 21, 22, 23, 24, 25,
        26, 27, 28, 29, 30, 31, 32, 33,
        34, 35, 37, 38, 39, 40, 41, 42,
        43, 44, 45, 46, 47, 49, 50,
        65, 67, 69, 75, 76, 78, 81, 82,
        83, 84, 85, 86, 87, 88, 89, 91,
        92, 95
    ]

    // Ported from Chromium's ui/events/keycodes/keyboard_code_conversion_mac.mm
    // KeyboardCodeFromKeyCode table. Values are Windows virtual-key codes.
    private static let windowsKeyCodesByMacVirtualKeyCode: [UInt32] = [
        65, 83, 68, 70, 72, 71, 90, 88,
        67, 86, 192, 66, 81, 87, 69, 82,
        89, 84, 49, 50, 51, 52, 54, 53,
        187, 57, 55, 189, 56, 48, 221, 79,
        85, 219, 73, 80, 13, 76, 74, 222,
        75, 186, 220, 188, 191, 78, 77, 190,
        9, 32, 192, 8, 0, 27, 93, 91,
        16, 20, 18, 17, 16, 18, 17, 0,
        128, 110, 0, 106, 0, 107, 0, 12,
        175, 174, 173, 111, 13, 0, 109, 129,
        130, 187, 96, 97, 98, 99, 100, 101,
        102, 103, 131, 104, 105, 0, 0, 0,
        116, 117, 118, 114, 119, 120, 0, 122,
        0, 124, 127, 125, 0, 121, 93, 123,
        0, 126, 45, 36, 33, 46, 115, 35,
        113, 34, 112, 37, 39, 40, 38, 0
    ]
}
