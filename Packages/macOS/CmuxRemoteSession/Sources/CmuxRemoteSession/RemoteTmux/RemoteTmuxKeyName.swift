/// A canonical tmux key name safe to place in a `send-keys` command.
///
/// The initializer accepts only known named keys, ASCII alphanumerics, and
/// validated `C-`/`M-`/`S-` modifiers. Literal text stays outside this type so
/// callers cannot accidentally interpolate arbitrary input into a tmux command.
public struct RemoteTmuxKeyName: Equatable, Sendable {
    /// The canonical spelling accepted by tmux, such as `End` or `C-S-Up`.
    public let value: String

    /// Resolves a CLI/socket key spelling to tmux's canonical key name.
    ///
    /// - Parameter rawName: A named key or modified key spelling.
    public init?(rawName: String) {
        let normalized = rawName.lowercased().replacingOccurrences(of: "+", with: "-")
        switch normalized {
        case "enter", "return": value = "Enter"; return
        case "tab": value = "Tab"; return
        case "escape", "esc": value = "Escape"; return
        case "backspace": value = "BSpace"; return
        case "shift-tab", "backtab": value = "BTab"; return
        case "space": value = "Space"; return
        case "sigint": value = "C-c"; return
        case "eof": value = "C-d"; return
        case "sigtstp": value = "C-z"; return
        case "sigquit": value = "C-\\"; return
        default: break
        }

        let parts = normalized.split(separator: "-").map(String.init)
        guard let rawBase = parts.last else { return nil }
        let base: String
        if rawBase.count == 1,
           let byte = rawBase.utf8.first,
           (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122) {
            base = rawBase
        } else if rawBase.first == "f",
                  let number = Int(rawBase.dropFirst()),
                  (1...12).contains(number) {
            base = "F\(number)"
        } else {
            switch rawBase {
            case "home": base = "Home"
            case "end": base = "End"
            case "insert", "ic": base = "IC"
            case "delete", "del", "dc", "forward_delete": base = "DC"
            case "pageup", "page_up", "pgup", "ppage": base = "PPage"
            case "pagedown", "page_down", "pgdn", "npage": base = "NPage"
            case "up", "arrow_up", "arrowup": base = "Up"
            case "down", "arrow_down", "arrowdown": base = "Down"
            case "left", "arrow_left", "arrowleft": base = "Left"
            case "right", "arrow_right", "arrowright": base = "Right"
            default: return nil
            }
        }

        var hasControl = false
        var hasMeta = false
        var hasShift = false
        for modifier in parts.dropLast() {
            switch modifier {
            case "c", "ctrl", "control": hasControl = true
            case "m", "alt", "opt", "option": hasMeta = true
            case "s", "shift": hasShift = true
            default: return nil
            }
        }

        var modifiers: [String] = []
        modifiers.reserveCapacity(3)
        if hasControl { modifiers.append("C") }
        if hasMeta { modifiers.append("M") }
        if hasShift { modifiers.append("S") }
        value = (modifiers + [base]).joined(separator: "-")
    }
}
