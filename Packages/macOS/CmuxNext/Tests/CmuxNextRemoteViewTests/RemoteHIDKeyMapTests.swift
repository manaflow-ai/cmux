import AppKit
import Carbon.HIToolbox
import Testing
@testable import CmuxNextRemoteView

/// The key table against an independent reference: Carbon's `kVK_*`
/// constants on one side and the USB HID Usage Tables (keyboard page 0x07)
/// on the other, for every printable US key and every modifier.
struct RemoteHIDKeyMapTests {
    /// Each printable US character (unshifted and shifted) -> (kVK, HID id).
    static let printable: [(Character, Character?, Int, UInt32)] = [
        ("a", "A", kVK_ANSI_A, 0x04), ("b", "B", kVK_ANSI_B, 0x05), ("c", "C", kVK_ANSI_C, 0x06),
        ("d", "D", kVK_ANSI_D, 0x07), ("e", "E", kVK_ANSI_E, 0x08), ("f", "F", kVK_ANSI_F, 0x09),
        ("g", "G", kVK_ANSI_G, 0x0A), ("h", "H", kVK_ANSI_H, 0x0B), ("i", "I", kVK_ANSI_I, 0x0C),
        ("j", "J", kVK_ANSI_J, 0x0D), ("k", "K", kVK_ANSI_K, 0x0E), ("l", "L", kVK_ANSI_L, 0x0F),
        ("m", "M", kVK_ANSI_M, 0x10), ("n", "N", kVK_ANSI_N, 0x11), ("o", "O", kVK_ANSI_O, 0x12),
        ("p", "P", kVK_ANSI_P, 0x13), ("q", "Q", kVK_ANSI_Q, 0x14), ("r", "R", kVK_ANSI_R, 0x15),
        ("s", "S", kVK_ANSI_S, 0x16), ("t", "T", kVK_ANSI_T, 0x17), ("u", "U", kVK_ANSI_U, 0x18),
        ("v", "V", kVK_ANSI_V, 0x19), ("w", "W", kVK_ANSI_W, 0x1A), ("x", "X", kVK_ANSI_X, 0x1B),
        ("y", "Y", kVK_ANSI_Y, 0x1C), ("z", "Z", kVK_ANSI_Z, 0x1D),
        ("1", "!", kVK_ANSI_1, 0x1E), ("2", "@", kVK_ANSI_2, 0x1F), ("3", "#", kVK_ANSI_3, 0x20),
        ("4", "$", kVK_ANSI_4, 0x21), ("5", "%", kVK_ANSI_5, 0x22), ("6", "^", kVK_ANSI_6, 0x23),
        ("7", "&", kVK_ANSI_7, 0x24), ("8", "*", kVK_ANSI_8, 0x25), ("9", "(", kVK_ANSI_9, 0x26),
        ("0", ")", kVK_ANSI_0, 0x27),
        ("-", "_", kVK_ANSI_Minus, 0x2D), ("=", "+", kVK_ANSI_Equal, 0x2E),
        ("[", "{", kVK_ANSI_LeftBracket, 0x2F), ("]", "}", kVK_ANSI_RightBracket, 0x30),
        ("\\", "|", kVK_ANSI_Backslash, 0x31), (";", ":", kVK_ANSI_Semicolon, 0x33),
        ("'", "\"", kVK_ANSI_Quote, 0x34), ("`", "~", kVK_ANSI_Grave, 0x35),
        (",", "<", kVK_ANSI_Comma, 0x36), (".", ">", kVK_ANSI_Period, 0x37), ("/", "?", kVK_ANSI_Slash, 0x38),
        (" ", nil, kVK_Space, 0x2C),
    ]

    @Test func everyPrintableUSKeyMapsToItsHIDUsage() {
        var covered = Set<Character>()
        for (plain, shifted, keyCode, id) in Self.printable {
            #expect(RemoteHIDKeyMap.usage(forKeyCode: UInt16(keyCode)) == 0x0007_0000 | id, "\(plain)")
            covered.insert(plain)
            if let shifted { covered.insert(shifted) }
        }
        // All 95 printable ASCII characters are reachable (with Shift where needed).
        let ascii = (0x20...0x7E).map { Character(UnicodeScalar($0)!) }
        #expect(Set(ascii).subtracting(covered).isEmpty)
    }

    @Test func modifiersMapToLeftAndRightUsages() {
        let modifiers: [(Int, UInt32)] = [
            (kVK_Control, 0xE0), (kVK_Shift, 0xE1), (kVK_Option, 0xE2), (kVK_Command, 0xE3),
            (kVK_RightControl, 0xE4), (kVK_RightShift, 0xE5), (kVK_RightOption, 0xE6), (kVK_RightCommand, 0xE7),
            (kVK_CapsLock, 0x39),
        ]
        for (keyCode, id) in modifiers {
            #expect(RemoteHIDKeyMap.usage(forKeyCode: UInt16(keyCode)) == 0x0007_0000 | id)
            #expect(RemoteHIDKeyMap.isModifier(keyCode: UInt16(keyCode)))
        }
        #expect(RemoteHIDKeyMap.usage(forKeyCode: UInt16(kVK_Function)) == nil)
    }

    @Test func editingNavigationAndFunctionKeys() {
        let keys: [(Int, UInt32)] = [
            (kVK_Return, 0x28), (kVK_Escape, 0x29), (kVK_Delete, 0x2A), (kVK_Tab, 0x2B),
            (kVK_ForwardDelete, 0x4C), (kVK_Home, 0x4A), (kVK_End, 0x4D), (kVK_PageUp, 0x4B), (kVK_PageDown, 0x4E),
            (kVK_LeftArrow, 0x50), (kVK_RightArrow, 0x4F), (kVK_UpArrow, 0x52), (kVK_DownArrow, 0x51),
            (kVK_F1, 0x3A), (kVK_F2, 0x3B), (kVK_F3, 0x3C), (kVK_F4, 0x3D), (kVK_F5, 0x3E), (kVK_F6, 0x3F),
            (kVK_F7, 0x40), (kVK_F8, 0x41), (kVK_F9, 0x42), (kVK_F10, 0x43), (kVK_F11, 0x44), (kVK_F12, 0x45),
            (kVK_F13, 0x68), (kVK_F16, 0x6B), (kVK_F20, 0x6F),
            (kVK_ANSI_Keypad0, 0x62), (kVK_ANSI_Keypad9, 0x61), (kVK_ANSI_KeypadEnter, 0x58),
            (kVK_ANSI_KeypadDecimal, 0x63), (kVK_ANSI_KeypadEquals, 0x67),
            (kVK_ISO_Section, 0x64), (kVK_JIS_Yen, 0x89), (kVK_JIS_Underscore, 0x87),
            (kVK_JIS_Kana, 0x90), (kVK_JIS_Eisu, 0x91),
        ]
        for (keyCode, id) in keys {
            #expect(RemoteHIDKeyMap.usage(forKeyCode: UInt16(keyCode)) == 0x0007_0000 | id, "kVK \(keyCode)")
        }
    }

    @Test func tableIsInjectiveAndReversible() {
        let ids = RemoteHIDKeyMap.table.filter { $0 != 0 }
        #expect(Set(ids).count == ids.count)
        for code in UInt16(0)..<0x80 {
            guard let usage = RemoteHIDKeyMap.usage(forKeyCode: code) else { continue }
            #expect(RemoteHIDKeyMap.keyCode(forUsage: usage) == code)
        }
        #expect(RemoteHIDKeyMap.usage(forKeyCode: 0x200) == nil)
    }
}
