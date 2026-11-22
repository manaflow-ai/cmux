import AppKit

/// One keystroke from cmux.json, independent of the action registry's types
/// so parsing can run off the main actor. `key` uses NSMenuItem
/// key-equivalent semantics (lowercase character or function-key character),
/// the same as `CmuxNextActions.Shortcut`.
public struct ShortcutStrokeSpec: Sendable, Hashable {
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    public var hasModifier: Bool { command || shift || option || control }
}

/// A parsed `shortcuts.bindings.<actionID>` value.
public enum ShortcutBinding: Sendable, Hashable {
    /// The user removed the shortcut (`null`, `""`, `none`, `clear`,
    /// `unbound`, `disabled`, or the recorder's empty-key object).
    case unbound
    case stroke(ShortcutStrokeSpec)
    /// A two-stroke chord (`["ctrl+b", "c"]`); the first key needs Command
    /// or Control.
    case chord(ShortcutStrokeSpec, ShortcutStrokeSpec)
}

/// Reads and writes the cmux.json shortcut formats the old app accepts:
/// `"cmd+shift+p"`, `["ctrl+b", "c"]`, the unbind tokens, and the Settings
/// recorder's object form `{ "first": { "key": "p", "command": true, ... } }`.
public struct ShortcutBindingFormat {
    public init() {}
    static let unboundTokens: Set<String> = ["", "none", "clear", "unbound", "disabled"]

    /// Parses one binding value. Nil when the value is not a valid binding.
    public static func parse(_ value: JSONValue) -> ShortcutBinding? {
        switch value {
        case .null:
            return .unbound
        case .string(let text):
            if unboundTokens.contains(text.trimmingCharacters(in: .whitespaces).lowercased()) { return .unbound }
            return parseStroke(text).map(ShortcutBinding.stroke)
        case .array(let items):
            let strokes = items.compactMap { $0.stringValue.flatMap(parseStroke) }
            guard strokes.count == items.count else { return nil }
            switch strokes.count {
            case 0: return .unbound
            case 1: return .stroke(strokes[0])
            case 2: return .chord(strokes[0], strokes[1])
            default: return nil
            }
        case .object(let members):
            guard let first = members["first"].flatMap(parseStrokeObject) else { return nil }
            if first.key.isEmpty { return .unbound }
            if let secondValue = members["second"], !secondValue.isNull {
                guard let second = parseStrokeObject(secondValue) else { return nil }
                return .chord(first, second)
            }
            return .stroke(first)
        default:
            return nil
        }
    }

    /// Parses `cmd+shift+p`, `⌘⇧P`-style modifier tokens joined by `+`.
    public static func parseStroke(_ text: String) -> ShortcutStrokeSpec? {
        let rawParts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let lastRaw = rawParts.last else { return nil }
        // `cmd++` means the plus key.
        var parts = rawParts
        var keyToken = lastRaw
        if lastRaw.isEmpty, rawParts.count >= 2, rawParts[rawParts.count - 2].isEmpty {
            parts.removeLast()
            keyToken = "+"
        }
        var stroke = ShortcutStrokeSpec(key: "")
        for modifier in parts.dropLast() {
            switch modifier.trimmingCharacters(in: .whitespaces).lowercased() {
            case "cmd", "command", "⌘": stroke.command = true
            case "shift", "⇧": stroke.shift = true
            case "opt", "option", "alt", "⌥": stroke.option = true
            case "ctrl", "control", "ctl", "⌃": stroke.control = true
            case "": continue
            default: return nil
            }
        }
        guard let key = keyEquivalent(forToken: keyToken) else { return nil }
        stroke.key = key
        return stroke
    }

    private static func parseStrokeObject(_ value: JSONValue) -> ShortcutStrokeSpec? {
        guard case .object(let members) = value, let rawKey = members["key"]?.stringValue else { return nil }
        let key = rawKey.isEmpty ? "" : (keyEquivalent(forToken: rawKey) ?? rawKey.lowercased())
        return ShortcutStrokeSpec(
            key: key,
            command: members["command"]?.boolValue ?? false,
            shift: members["shift"]?.boolValue ?? false,
            option: members["option"]?.boolValue ?? false,
            control: members["control"]?.boolValue ?? false
        )
    }

    /// Maps a config key token to a key-equivalent character.
    static func keyEquivalent(forToken rawToken: String) -> String? {
        let trimmed = rawToken.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return rawToken == " " ? " " : nil }
        switch trimmed.lowercased() {
        case "left", "arrowleft", "leftarrow", "←": return functionKey(NSLeftArrowFunctionKey)
        case "right", "arrowright", "rightarrow", "→": return functionKey(NSRightArrowFunctionKey)
        case "up", "arrowup", "uparrow", "↑": return functionKey(NSUpArrowFunctionKey)
        case "down", "arrowdown", "downarrow", "↓": return functionKey(NSDownArrowFunctionKey)
        case "tab", "⇥": return "\t"
        case "return", "enter", "↩": return "\r"
        case "escape", "esc", "⎋": return "\u{1B}"
        case "delete", "backspace", "⌫": return "\u{8}"
        case "space", "spacebar", "<space>": return " "
        case "comma": return ","
        case "period", "dot": return "."
        case "slash": return "/"
        case "backslash": return "\\"
        case "semicolon": return ";"
        case "quote", "apostrophe": return "'"
        case "backtick", "grave": return "`"
        case "minus", "hyphen": return "-"
        case "plus", "equals": return "="
        case "leftbracket", "openbracket": return "["
        case "rightbracket", "closebracket": return "]"
        case "home": return functionKey(NSHomeFunctionKey)
        case "end": return functionKey(NSEndFunctionKey)
        case "pageup": return functionKey(NSPageUpFunctionKey)
        case "pagedown": return functionKey(NSPageDownFunctionKey)
        case let lowered:
            if lowered.hasPrefix("f"), let number = Int(lowered.dropFirst()), (1...20).contains(number) {
                return functionKey(NSF1FunctionKey + number - 1)
            }
            guard lowered.count == 1 else { return nil }
            return lowered
        }
    }

    /// The config string for a stroke (`cmd+shift+p`), as the Settings
    /// writer stores it.
    public static func configString(_ stroke: ShortcutStrokeSpec) -> String {
        var parts: [String] = []
        if stroke.command { parts.append("cmd") }
        if stroke.shift { parts.append("shift") }
        if stroke.option { parts.append("opt") }
        if stroke.control { parts.append("ctrl") }
        parts.append(configToken(forKey: stroke.key))
        return parts.joined(separator: "+")
    }

    static func configToken(forKey key: String) -> String {
        switch key {
        case functionKey(NSLeftArrowFunctionKey): return "left"
        case functionKey(NSRightArrowFunctionKey): return "right"
        case functionKey(NSUpArrowFunctionKey): return "up"
        case functionKey(NSDownArrowFunctionKey): return "down"
        case functionKey(NSHomeFunctionKey): return "home"
        case functionKey(NSEndFunctionKey): return "end"
        case functionKey(NSPageUpFunctionKey): return "pageup"
        case functionKey(NSPageDownFunctionKey): return "pagedown"
        case "\t": return "tab"
        case "\r": return "return"
        case "\u{1B}": return "escape"
        case "\u{8}", "\u{7F}": return "delete"
        case " ": return "space"
        case "+": return "plus"
        default:
            if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1,
               (NSF1FunctionKey...NSF1FunctionKey + 19).contains(Int(scalar.value)) {
                return "f\(Int(scalar.value) - NSF1FunctionKey + 1)"
            }
            return key
        }
    }

    private static func functionKey(_ code: Int) -> String {
        // Function-key codes are valid private-use scalars; NUL stands in otherwise (no trap).
        String(Character(UnicodeScalar(UInt32(code)) ?? UnicodeScalar(0)))
    }
}
