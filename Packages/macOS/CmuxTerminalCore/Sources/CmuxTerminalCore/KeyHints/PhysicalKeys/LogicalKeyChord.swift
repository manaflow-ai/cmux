/// A chord as the app receives it, after every remap: the modifiers held
/// and the key pressed. This is what an agent's key hint asks for.
struct LogicalKeyChord: Hashable, Sendable {
    var modifiers: Set<KeyboardModifier>
    var key: PhysicalKey

    /// The chord for a named key in `TerminalSurface.sendNamedKey` form
    /// (`ctrl+o`, `shift+tab`, `escape`), or `nil` when the key has no fixed
    /// physical position (`?` depends on the layout).
    init?(agentKey: String) {
        let parts = agentKey.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let base = parts.last, !base.isEmpty else { return nil }
        var modifiers = Set<KeyboardModifier>()
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option", "opt", "meta": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "cmd", "command", "super": modifiers.insert(.command)
            default: return nil
            }
        }
        let keyCode: String
        switch base {
        case "escape", "esc": keyCode = "escape"
        case "enter", "return": keyCode = "return_or_enter"
        case "space": keyCode = "spacebar"
        case "tab": keyCode = "tab"
        case "up": keyCode = "up_arrow"
        case "down": keyCode = "down_arrow"
        case "left": keyCode = "left_arrow"
        case "right": keyCode = "right_arrow"
        case "backspace": keyCode = "delete_or_backspace"
        case "delete": keyCode = "delete_forward"
        case "pageup": keyCode = "page_up"
        case "pagedown": keyCode = "page_down"
        case "home", "end": keyCode = base
        case "/": keyCode = "slash"
        default:
            guard base.count == 1, let character = base.first, character.isASCII,
                  character.isLetter || character.isNumber else { return nil }
            keyCode = base
        }
        guard let key = PhysicalKey(karabinerKeyCode: keyCode) else { return nil }
        self.modifiers = modifiers
        self.key = key
    }

    init(modifiers: Set<KeyboardModifier>, key: PhysicalKey) {
        self.modifiers = modifiers
        self.key = key
    }

    /// The chord pressed with the left-hand modifier keys that print the
    /// same glyphs, which is what someone reading the hint presses.
    var asPrinted: PhysicalKeyChord {
        PhysicalKeyChord(modifiers: modifiers.map(\.leftKey), key: key)
    }
}
