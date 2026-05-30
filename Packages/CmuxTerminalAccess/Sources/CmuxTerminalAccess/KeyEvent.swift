// SPDX-License-Identifier: MIT

/// A semantic key press (modifiers + key identity). The actual byte
/// sequence sent to the PTY is decided by ghostty's encoder per the
/// surface's active modes (DECCKM, kitty, modifyOtherKeys).
public struct KeyEvent: Hashable, Sendable {
    /// Modifier flags held while the key was pressed.
    public let mods: Set<KeyMod>
    /// The pressed key.
    public let key: NamedKey

    /// Creates a key event from its parts.
    public init(mods: Set<KeyMod>, key: NamedKey) {
        self.mods = mods
        self.key = key
    }

    /// Parses `"Mod+Mod+Key"` per D21. **Throwing only** — no Optional
    /// overload. Modifier names are case-insensitive in
    /// `{Ctrl, Alt|Opt|Option, Shift, Cmd|Meta|Super}`. The final segment
    /// is the key name; see ``NamedKey``.
    ///
    /// - Throws: ``KeyEventParseError`` describing the failure shape.
    public static func parse(_ s: String) throws -> KeyEvent {
        guard !s.isEmpty else { throw KeyEventParseError.empty }
        let parts = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty }) else { throw KeyEventParseError.malformed(s) }
        guard let keyName = parts.last else { throw KeyEventParseError.malformed(s) }
        var mods: Set<KeyMod> = []
        for m in parts.dropLast() {
            switch m.lowercased() {
            case "ctrl": mods.insert(.ctrl)
            case "alt", "opt", "option": mods.insert(.alt)
            case "shift": mods.insert(.shift)
            case "cmd", "meta", "super": mods.insert(.cmd)
            default: throw KeyEventParseError.unknownModifier(m)
            }
        }
        return KeyEvent(mods: mods, key: try NamedKey.parse(keyName))
    }
}

extension NamedKey {
    /// Parses a single key segment of a ``KeyEvent`` grammar string.
    ///
    /// - Throws: ``KeyEventParseError/unknownKey(_:)`` on unrecognised
    ///   input.
    public static func parse(_ s: String) throws -> NamedKey {
        if s.count == 1, let ch = s.first,
           ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol {
            return .char(Character(ch.lowercased()))
        }
        switch s.lowercased() {
        case "enter", "return": return .enter
        case "tab": return .tab
        case "escape", "esc": return .escape
        case "space": return .space
        case "backspace", "bs": return .backspace
        case "delete", "del": return .delete
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        case "home": return .home
        case "end": return .end
        case "pageup", "pgup": return .pageUp
        case "pagedown", "pgdn": return .pageDown
        default:
            if s.count >= 2, s.first?.lowercased() == "f",
               let n = Int(s.dropFirst()), (1...24).contains(n) {
                return .f(n)
            }
            throw KeyEventParseError.unknownKey(s)
        }
    }
}
