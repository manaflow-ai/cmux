import Foundation

/// A shortcut binding as it lives on disk: one or two ``ShortcutStroke``s.
///
/// A single-stroke binding fires when the user presses the recorded
/// modifiers + key. A two-stroke ("chord") binding is the tmux-style
/// prefix pattern: press the first stroke, then the second within a
/// short window. ``isUnbound`` represents an explicit "no shortcut for
/// this action" assignment so users can suppress an inherited default.
public struct StoredShortcut: Sendable, Equatable, Hashable, Codable, SettingCodable {
    /// The primary stroke. Empty `key` means the shortcut is unbound.
    public let first: ShortcutStroke

    /// Optional second stroke (chord). `nil` means single-stroke.
    public let second: ShortcutStroke?

    /// A binding that explicitly clears any inherited default.
    public static let unbound = StoredShortcut(
        first: ShortcutStroke(key: "")
    )

    public init(first: ShortcutStroke, second: ShortcutStroke? = nil) {
        self.first = first
        self.second = second
    }

    /// True when this binding is the explicit "no shortcut" marker.
    public var isUnbound: Bool { first.key.isEmpty && second == nil }

    /// True when the binding fires on two consecutive strokes.
    public var hasChord: Bool { second != nil }

    // MARK: - SettingCodable

    public static func decodeFromUserDefaults(_ raw: Any?) -> StoredShortcut? {
        guard let data = raw as? Data else { return nil }
        return try? JSONDecoder().decode(StoredShortcut.self, from: data)
    }

    public func encodeForUserDefaults() -> Any {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decodeFromJSON(_ raw: Any?) -> StoredShortcut? {
        guard let raw else { return nil }
        // Accept every schema-valid binding form (`$defs.shortcutBinding`) so a
        // hand-authored string stroke, chord array, or unbind sentinel loads
        // into the UI model instead of being dropped. Dropping any one entry
        // makes the all-or-nothing dictionary decode blank the entire bindings
        // map, which is what left the Settings UI showing no shortcuts. The
        // grammar mirrors the app target's runtime reader so a UI-loaded binding
        // and a runtime-resolved one agree on the canonical key form.
        if raw is NSNull {
            return .unbound
        }
        if let string = raw as? String {
            return parseConfig(string)
        }
        if let strokes = raw as? [String] {
            return parseConfig(strokes: strokes)
        }
        if let object = raw as? [String: Any] {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed) else {
                return nil
            }
            return try? JSONDecoder().decode(StoredShortcut.self, from: data)
        }
        return nil
    }

    public func encodeForJSON() -> Any {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return NSNull()
        }
        return object
    }
}

// MARK: - Config string / chord / sentinel parsing
//
// Mirrors the app target's `ShortcutStroke.parseConfig` grammar so the Settings
// UI decodes the same hand-editable forms the runtime resolver accepts, and
// produces the same canonical `key` tokens (arrows as glyphs, Return as "\r",
// Tab as "\t", Space as "space", media as "media.*"). This is a lossless
// *decode* for display/preservation, so modifier-less ("bare") strokes are
// accepted here even though the recorder rejects them at record time.

extension StoredShortcut {
    /// Parses a binding value's string form (`"cmd+shift+up"`) or an unbind
    /// sentinel (`""`, `"none"`, `"clear"`, `"unbound"`, `"disabled"`).
    static func parseConfig(_ rawValue: String) -> StoredShortcut? {
        if isUnboundConfigToken(rawValue) { return .unbound }
        return parseConfig(strokes: [rawValue])
    }

    /// Parses a one- or two-stroke chord from its string strokes. An empty array
    /// is the unbind sentinel; more than two strokes is invalid.
    static func parseConfig(strokes: [String]) -> StoredShortcut? {
        if strokes.isEmpty { return .unbound }
        guard strokes.count <= 2 else { return nil }
        if strokes.count == 1, let only = strokes.first, isUnboundConfigToken(only) {
            return .unbound
        }
        let parsed = strokes.compactMap(ShortcutStroke.parseConfig(_:))
        guard parsed.count == strokes.count, let first = parsed.first else { return nil }
        return StoredShortcut(first: first, second: parsed.count == 2 ? parsed[1] : nil)
    }

    private static func isUnboundConfigToken(_ rawValue: String) -> Bool {
        if rawValue.isEmpty { return true }
        if rawValue == " " { return false }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return normalized == "none" || normalized == "clear" || normalized == "unbound" || normalized == "disabled"
    }
}

extension ShortcutStroke {
    /// Parses a single stroke string like `"cmd+shift+up"` into a stroke, or
    /// `nil` when a modifier token or the key token is unrecognized.
    static func parseConfig(_ rawValue: String) -> ShortcutStroke? {
        guard !rawValue.isEmpty else { return nil }
        let rawParts = rawValue.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let parts = rawParts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty, let lastRawPart = rawParts.last, !lastRawPart.isEmpty else {
            return nil
        }
        var command = false
        var shift = false
        var option = false
        var control = false
        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "cmd", "command", "⌘":
                command = true
            case "shift", "⇧":
                shift = true
            case "opt", "option", "alt", "⌥":
                option = true
            case "ctrl", "control", "ctl", "⌃":
                control = true
            default:
                return nil
            }
        }
        guard let key = parseConfigKeyToken(lastRawPart) else { return nil }
        return ShortcutStroke(key: key, command: command, shift: shift, option: option, control: control)
    }

    private static func parseConfigKeyToken(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return rawValue == " " ? "space" : nil
        }
        let lowered = trimmed.lowercased()
        switch lowered {
        case "left", "arrowleft", "leftarrow", "←":
            return "←"
        case "right", "arrowright", "rightarrow", "→":
            return "→"
        case "up", "arrowup", "uparrow", "↑":
            return "↑"
        case "down", "arrowdown", "downarrow", "↓":
            return "↓"
        case "tab":
            return "\t"
        case "return", "enter", "↩":
            return "\r"
        case "space", "spacebar", "<space>":
            return "space"
        case "comma":
            return ","
        case "period", "dot":
            return "."
        case "slash":
            return "/"
        case "backslash":
            return "\\"
        case "semicolon":
            return ";"
        case "quote", "apostrophe":
            return "'"
        case "backtick", "grave":
            return "`"
        case "minus", "hyphen":
            return "-"
        case "plus", "equals":
            return "="
        case "leftbracket", "openbracket":
            return "["
        case "rightbracket", "closebracket":
            return "]"
        case "volumeup", "mediavolumeup", "media.volumeup":
            return "media.volumeUp"
        case "volumedown", "mediavolumedown", "media.volumedown":
            return "media.volumeDown"
        case "brightnessup", "mediabrightnessup", "media.brightnessup":
            return "media.brightnessUp"
        case "brightnessdown", "mediabrightnessdown", "media.brightnessdown":
            return "media.brightnessDown"
        case "mute", "mediamute", "media.mute":
            return "media.mute"
        case "playpause", "mediaplaypause", "media.playpause":
            return "media.playPause"
        case "nexttrack", "medianext", "media.next", "media.nexttrack":
            return "media.next"
        case "previoustrack", "mediaprevious", "media.previous", "media.previoustrack":
            return "media.previous"
        default:
            if lowered.hasPrefix("f"),
               let number = Int(lowered.dropFirst()),
               (1...20).contains(number) {
                return "f\(number)"
            }
            guard lowered.count == 1 else { return nil }
            return lowered
        }
    }
}
