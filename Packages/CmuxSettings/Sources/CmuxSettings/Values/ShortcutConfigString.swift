import Foundation

/// Config-string parsing, formatting, and conflict detection for keyboard
/// shortcut bindings.
///
/// These live in `CmuxSettings` (not the app target) so that **one**
/// definition is shared by the `cmux settings shortcuts` CLI, the `cmux.json`
/// file store, the `cmux.json` config encoder, and the Settings UI. They were
/// moved out of the app's `KeyboardShortcutSettings.swift`; the only
/// app-coupled reference in the original (`firstStroke.modifierFlags.isEmpty`)
/// maps exactly to the package's ``ShortcutStroke/hasAnyModifier``.
///
/// A config token is `modifier+…+key`, e.g. `cmd+t`, `ctrl+shift+]`, `space`,
/// or `f5`. A binding is one token (single stroke) or two space-/array-
/// separated tokens (a tmux-style chord). `none` / `clear` / `unbound` /
/// `disabled` (and the empty string) mean "explicitly unbound".
extension ShortcutStroke {
    /// Parses a single config token into a stroke, or `nil` when malformed.
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

        guard let key = parseConfigKeyToken(lastRawPart) else { return nil }
        return ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }

    /// Renders the stroke back to a config token (`cmd+t`). When `preserveDigit`
    /// is `false`, a `1`–`9` digit key collapses to `1` (the numbered-digit
    /// family representative used by templates).
    public func configString(preserveDigit: Bool = true) -> String {
        var parts: [String] = []
        if command { parts.append("cmd") }
        if shift { parts.append("shift") }
        if option { parts.append("opt") }
        if control { parts.append("ctrl") }
        parts.append(configKeyString(preserveDigit: preserveDigit))
        return parts.joined(separator: "+")
    }

    /// Whether two strokes match exactly (same key + identical modifier set).
    /// This is the leaf conflict primitive shared with the app's recorder.
    public func conflictsExactly(with other: ShortcutStroke) -> Bool {
        key == other.key
            && command == other.command
            && shift == other.shift
            && option == other.option
            && control == other.control
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

extension StoredShortcut {
    /// Parses a one- or two-token binding string into a ``StoredShortcut``.
    /// Recognizes the unbound tokens (`none`, `clear`, `unbound`, `disabled`,
    /// empty). Returns `nil` when malformed.
    public static func parseConfig(_ rawValue: String, allowBareFirstStroke: Bool = false) -> StoredShortcut? {
        if isUnboundConfigToken(rawValue) {
            return .unbound
        }
        return parseConfig(strokes: [rawValue], allowBareFirstStroke: allowBareFirstStroke)
    }

    /// Parses an array of one or two config tokens into a binding. The first
    /// stroke must carry a modifier (or be `space`) unless `allowBareFirstStroke`
    /// is set — matching how a leading bare key would otherwise swallow ordinary
    /// typing.
    public static func parseConfig(strokes: [String], allowBareFirstStroke: Bool = false) -> StoredShortcut? {
        guard !strokes.isEmpty, strokes.count <= 2 else { return nil }
        if strokes.count == 1, let rawValue = strokes.first, isUnboundConfigToken(rawValue) {
            return .unbound
        }
        let parsedStrokes = strokes.compactMap(ShortcutStroke.parseConfig(_:))
        guard parsedStrokes.count == strokes.count, let firstStroke = parsedStrokes.first else {
            return nil
        }
        guard allowBareFirstStroke || firstStroke.hasAnyModifier || firstStroke.key == "space" else { return nil }
        let secondStroke = parsedStrokes.count == 2 ? parsedStrokes[1] : nil
        return StoredShortcut(first: firstStroke, second: secondStroke)
    }

    /// A stable config-string identity for the binding (`cmd+t`, `cmd+b c`, or
    /// `none` when unbound). Used for display and round-tripping.
    public var configIdentifier: String {
        if isUnbound { return "none" }
        if let second {
            return "\(first.configString()) \(second.configString())"
        }
        return first.configString()
    }

    /// Whether two bindings collide (would both fire on the same input).
    ///
    /// Mirrors the exact-match arm of the app's shortcut conflict logic: single
    /// strokes conflict on an exact match; two chords conflict only when both
    /// of their strokes match; a chord and a single stroke collide when the
    /// chord's first stroke equals the single stroke. Unbound bindings never
    /// conflict. (The app additionally treats `1`–`9` numbered-digit families as
    /// conflicting; that GUI-specific nuance is layered on app-side.)
    public func conflicts(with other: StoredShortcut) -> Bool {
        guard !isUnbound, !other.isUnbound else { return false }
        switch (second, other.second) {
        case (nil, nil):
            return first.conflictsExactly(with: other.first)
        case let (lhsSecond?, rhsSecond?):
            return first.conflictsExactly(with: other.first)
                && lhsSecond.conflictsExactly(with: rhsSecond)
        default:
            return first.conflictsExactly(with: other.first)
        }
    }

    private static func isUnboundConfigToken(_ rawValue: String) -> Bool {
        if rawValue.isEmpty { return true }
        if rawValue == " " { return false }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return normalized == "none" || normalized == "clear" || normalized == "unbound" || normalized == "disabled"
    }
}
