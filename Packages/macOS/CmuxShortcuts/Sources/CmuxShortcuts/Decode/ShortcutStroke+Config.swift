import Foundation
public import CmuxSettings

/// The `cmd+shift+x` config grammar for a single ``ShortcutStroke``.
///
/// ## Why this lives here
///
/// The cmux JSON config (`~/.config/cmux/cmux.json`) encodes a keyboard
/// shortcut as a hand-editable token string like `cmd+shift+t` or a named key
/// like `space`/`f5`/`media.playPause`. Turning that token grammar into a
/// ``ShortcutStroke`` value (and back) is pure string tokenizing and formatting
/// with no AppKit, window, or focus dependency, so it belongs in the
/// shortcut-decode layer next to ``ShortcutEventDecoding`` and the key table,
/// not on the app's settings god object.
///
/// The grammar is byte-identical to the legacy app-target implementation it was
/// lifted from: the same modifier spellings, the same named-key table, the same
/// digit-preservation rule, and the same `configString` ordering
/// (`cmd`, `shift`, `opt`, `ctrl`, then the key). Changing any token here is a
/// wire-format change to every user's `cmux.json`.
extension ShortcutStroke {
    /// Parses one config token (e.g. `"cmd+shift+t"`, `"space"`, `"cmd+f5"`)
    /// into a ``ShortcutStroke``, or `nil` when the token is empty, names an
    /// unknown modifier, or names an unknown key.
    ///
    /// The last `+`-separated component is the key; every earlier component is a
    /// modifier. Whitespace around each component is trimmed before matching,
    /// except that a literal single space token resolves to the `space` key.
    public static func parseConfig(_ rawValue: String) -> ShortcutStroke? {
        guard !rawValue.isEmpty else { return nil }

        let rawParts = rawValue.split(separator: "+", omittingEmptySubsequences: false)
            .map(String.init)
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

        guard let key = Self.parseConfigKeyToken(lastRawPart) else { return nil }
        return ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }

    /// Formats this stroke as a config token (e.g. `"cmd+shift+t"`).
    ///
    /// Modifiers are emitted in the fixed order `cmd`, `shift`, `opt`, `ctrl`,
    /// then the key. When `preserveDigit` is `false`, a numbered key `1`–`9`
    /// collapses to `1` so a numbered-action family serializes one canonical
    /// token; all other keys are emitted verbatim.
    public func configString(preserveDigit: Bool = true) -> String {
        var parts: [String] = []
        if command { parts.append("cmd") }
        if shift { parts.append("shift") }
        if option { parts.append("opt") }
        if control { parts.append("ctrl") }
        parts.append(configKeyString(preserveDigit: preserveDigit))
        return parts.joined(separator: "+")
    }

    private func configKeyString(preserveDigit: Bool) -> String {
        if preserveDigit {
            return key
        }
        if let digit = Int(key), (1...9).contains(digit) {
            return "1"
        }
        return key
    }

    /// Normalizes a single key token (the last `+`-separated component) into the
    /// platform-canonical key string, or `nil` for an unknown token.
    ///
    /// Resolves arrow/return/tab/space aliases, named punctuation, media keys,
    /// `f1`–`f20`, and single characters (lower-cased). An empty trimmed token
    /// resolves to `space` only when the original raw token was a literal space.
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
