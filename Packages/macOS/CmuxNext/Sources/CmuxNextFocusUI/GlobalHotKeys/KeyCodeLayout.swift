package import AppKit
package import Carbon.HIToolbox
package import CmuxNextActions

/// Maps a `Shortcut` key character to the virtual key code that types it.
/// Carbon hot keys name physical keys, while shortcuts name characters, so
/// `.` must become whichever key types `.` on the current layout.
package struct KeyCodeLayout: Sendable {
    private var codes: [String: UInt32]

    package init(codes: [String: UInt32]) {
        self.codes = codes
    }

    package func keyCode(for key: String) -> UInt32? {
        codes[key.lowercased()]
    }

    /// Keys that do not depend on the layout: space, return, arrows,
    /// function keys.
    package static let fixed: [String: UInt32] = {
        var codes: [String: UInt32] = [
            Shortcut.spaceKey: UInt32(kVK_Space),
            Shortcut.returnKey: UInt32(kVK_Return),
            Shortcut.tabKey: UInt32(kVK_Tab),
            Shortcut.escapeKey: UInt32(kVK_Escape),
            Shortcut.deleteKey: UInt32(kVK_Delete),
            "\u{7F}": UInt32(kVK_Delete),
            Shortcut.upArrowKey: UInt32(kVK_UpArrow),
            Shortcut.downArrowKey: UInt32(kVK_DownArrow),
            Shortcut.leftArrowKey: UInt32(kVK_LeftArrow),
            Shortcut.rightArrowKey: UInt32(kVK_RightArrow)
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
        ]
        for (offset, code) in functionKeys.enumerated() {
            guard let scalar = UnicodeScalar(UInt32(NSF1FunctionKey + offset)) else { continue }
            codes[String(Character(scalar))] = UInt32(code)
        }
        return codes
    }()

    /// The numeric keypad's key codes (kVK_ANSI_Keypad*).
    package static let keypad: ClosedRange<Int> = kVK_ANSI_KeypadDecimal...kVK_ANSI_Keypad9

    /// US ANSI, the fallback when the current layout cannot be read.
    package static let ansi: KeyCodeLayout = {
        var codes = fixed
        for (code, key) in Shortcut.qwertyKeys { codes[key] = UInt32(code) }
        return KeyCodeLayout(codes: codes)
    }()

    /// The layout selected now: each printable character maps to the first
    /// key that types it unshifted. Keypad keys are skipped, since most
    /// laptops lack them; a character the main rows type only shifted (`.`
    /// on AZERTY) keeps its ANSI position.
    package static func current() -> KeyCodeLayout {
        var layout = ansi
        var typed: [String: UInt32] = [:]
        for (code, key) in typedKeys() where typed[key] == nil { typed[key] = UInt32(code) }
        for (key, code) in typed { layout.codes[key] = code }
        return layout
    }

    /// The `Shortcut` key each physical key has on the selected layout (a
    /// Ghostty physical trigger such as `key_h` or `arrow_left` as a table
    /// key): what it types unshifted, else its US ANSI character; arrows,
    /// Return, Tab, Space, Escape, Delete and the navigation keys by their
    /// key-equivalent characters.
    package static func currentKeyNames() -> [UInt16: String] {
        var names: [UInt16: String] = [:]
        for (key, code) in ansi.codes where key != Shortcut.deleteKey { names[UInt16(code)] = key }
        let navigation: [(Int, Int)] = [(kVK_Home, NSHomeFunctionKey), (kVK_End, NSEndFunctionKey), (kVK_PageUp, NSPageUpFunctionKey),
                                        (kVK_PageDown, NSPageDownFunctionKey), (kVK_ForwardDelete, NSDeleteFunctionKey)]
        for (code, character) in navigation {
            if let scalar = UnicodeScalar(UInt32(character)) { names[UInt16(code)] = String(Character(scalar)) }
        }
        for (code, key) in typedKeys() { names[code] = key }
        return names
    }

    /// What each main-row key types unshifted on the selected layout, by
    /// ascending key code; empty when the layout cannot be read.
    private static func typedKeys() -> [(code: UInt16, key: String)] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var typed: [(code: UInt16, key: String)] = []
        data.withUnsafeBytes { raw in
            guard let keyboard = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in UInt16(0)..<128 where !Self.keypad.contains(Int(code)) {
                var deadKeyState: UInt32 = 0
                var length = 0
                let capacity = 4
                var characters = [UniChar](repeating: 0, count: capacity)
                let status = UCKeyTranslate(
                    keyboard, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                    capacity, &length, &characters
                )
                guard status == noErr, length == 1, characters[0] > 0x20, characters[0] != 0x7F else { continue }
                typed.append((code, String(utf16CodeUnits: characters, count: length).lowercased()))
            }
        }
        return typed
    }
}
