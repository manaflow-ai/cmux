public import AppKit
import Carbon.HIToolbox

/// `app.shortcutLayout` Keep QWERTY Positions (Settings › Keyboard › Keyboard
/// Layout, design/keyboard-style.md): a Command or Control shortcut means the
/// key at its US QWERTY position rather than the character the selected layout
/// types, as macOS's "Dvorak - QWERTY Command" layout. A Dvorak typist then
/// finds Cmd-C, Cmd-V and Cmd-T where a US keyboard has them. Follow My Layout
/// (the default) keeps the typed character (#16237). The switch is
/// ``ActionRegistry/matchesQwertyPositions``; key readers take it as an
/// argument. This is the native half until the app FFI pin carries
/// cmux-keymap (`cmux_keymap_candidates`, the same table in Rust); then the
/// readers call it instead.
extension Shortcut {
    /// The character each printable key types on US ANSI QWERTY, by key code.
    public nonisolated static let qwertyKeys: [UInt16: String] = {
        let keys: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma,
            ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave
        ]
        return Dictionary(uniqueKeysWithValues: keys.map { (UInt16($0.value), $0.key) })
    }()

    /// The QWERTY key a key-down means when `qwerty` is on and Command or
    /// Control is held; nil otherwise (or for a key with no QWERTY character,
    /// such as an arrow), which keeps the typed-letter reading.
    nonisolated static func qwertyKey(for event: NSEvent, qwerty: Bool) -> String? {
        guard qwerty, !event.modifierFlags.intersection([.command, .control]).isEmpty else { return nil }
        return qwertyKeys[event.keyCode]
    }
}

extension ActionRegistry {
    /// ``shortcuts(for:qwerty:)`` with this registry's `app.shortcutLayout`.
    public func shortcuts(for event: NSEvent) -> [Shortcut] {
        Self.shortcuts(for: event, qwerty: matchesQwertyPositions)
    }
}

extension ActionRegistry {
    /// The stroke a key-down records in the shortcut recorder: its first
    /// reading (as the dispatcher matches it), or nil for a bare modifier.
    public func stroke(for event: NSEvent) -> Shortcut? {
        shortcuts(for: event).first { !$0.key.isEmpty }
    }
}
