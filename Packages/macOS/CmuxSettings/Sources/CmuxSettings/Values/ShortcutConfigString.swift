import Foundation

/// Config-string parsing, formatting, and conflict detection for the catalog's
/// keyboard-shortcut value types (``CmuxSettings/ShortcutStroke`` /
/// ``CmuxSettings/StoredShortcut``), used by the catalog-driven
/// `cmux settings shortcuts` engine which reads and writes the
/// `shortcuts.bindings` catalog entry.
///
/// The app target carries a parallel, identically-named pair of shortcut types
/// (a flat-chord runtime model in `KeyboardShortcutSettings.swift`) with its own
/// copy of these helpers; the two type hierarchies are distinct, so each needs
/// its own parser. This package copy mirrors the app's grammar exactly (the
/// app's lone AppKit-coupled check, `firstStroke.modifierFlags.isEmpty`, maps to
/// ``ShortcutStroke/hasAnyModifier`` here) so bindings round-trip identically
/// through `cmux.json` regardless of which side writes them.
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

    /// Whether two bindings collide (would both fire on the same input),
    /// assuming neither uses numbered-digit matching. See the richer overload
    /// for actions whose `1`–`9` digit family collides as a unit.
    public func conflicts(with other: StoredShortcut) -> Bool {
        conflicts(
            with: other,
            selfUsesNumberedDigitMatching: false,
            otherUsesNumberedDigitMatching: false
        )
    }

    /// Whether two bindings collide, honoring each action's numbered-digit
    /// matching policy. This is a faithful port of the app's
    /// `KeyboardShortcutSettings.shortcutsConflict` so `cmux settings shortcuts`
    /// detects the same conflicts the runtime router does: single strokes
    /// conflict on an exact match; two chords conflict only when both strokes
    /// match; a chord vs. single stroke collides when the chord's first stroke
    /// matches the single stroke. When an action uses numbered-digit matching,
    /// any `1`–`9` key with the same modifiers collides with the whole family.
    /// Unbound bindings never conflict.
    public func conflicts(
        with other: StoredShortcut,
        selfUsesNumberedDigitMatching: Bool,
        otherUsesNumberedDigitMatching: Bool
    ) -> Bool {
        guard !isUnbound, !other.isUnbound else { return false }
        switch (second, other.second) {
        case (nil, nil):
            return Self.strokeMatchersConflict(
                first, selfUsesNumberedDigitMatching,
                other.first, otherUsesNumberedDigitMatching
            )
        case let (lhsSecond?, rhsSecond?):
            guard first.conflictsExactly(with: other.first) else { return false }
            return Self.strokeMatchersConflict(
                lhsSecond, selfUsesNumberedDigitMatching,
                rhsSecond, otherUsesNumberedDigitMatching
            )
        case (.some, nil):
            // A chord's first stroke matches exactly (it is not a digit family).
            return Self.strokeMatchersConflict(
                first, false,
                other.first, otherUsesNumberedDigitMatching
            )
        case (nil, .some):
            return Self.strokeMatchersConflict(
                first, selfUsesNumberedDigitMatching,
                other.first, false
            )
        }
    }

    private static func strokeMatchersConflict(
        _ lhs: ShortcutStroke, _ lhsNumbered: Bool,
        _ rhs: ShortcutStroke, _ rhsNumbered: Bool
    ) -> Bool {
        switch (lhsNumbered, rhsNumbered) {
        case (false, false):
            return lhs.conflictsExactly(with: rhs)
        case (true, true):
            return numberedDigitStrokesConflict(lhs, rhs)
        case (true, false):
            return numberedDigitStrokeConflictsWithExact(numbered: lhs, exact: rhs)
        case (false, true):
            return numberedDigitStrokeConflictsWithExact(numbered: rhs, exact: lhs)
        }
    }

    private static func numberedDigitStrokesConflict(_ lhs: ShortcutStroke, _ rhs: ShortcutStroke) -> Bool {
        guard isNumberedDigitStroke(lhs), isNumberedDigitStroke(rhs) else { return false }
        return lhs.command == rhs.command && lhs.shift == rhs.shift
            && lhs.option == rhs.option && lhs.control == rhs.control
    }

    private static func numberedDigitStrokeConflictsWithExact(numbered: ShortcutStroke, exact: ShortcutStroke) -> Bool {
        guard isNumberedDigitStroke(numbered), isNumberedDigitStroke(exact) else { return false }
        return numbered.command == exact.command && numbered.shift == exact.shift
            && numbered.option == exact.option && numbered.control == exact.control
    }

    private static func isNumberedDigitStroke(_ stroke: ShortcutStroke) -> Bool {
        guard let digit = Int(stroke.key) else { return false }
        return (1...9).contains(digit)
    }

    private static func isUnboundConfigToken(_ rawValue: String) -> Bool {
        if rawValue.isEmpty { return true }
        if rawValue == " " { return false }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return normalized == "none" || normalized == "clear" || normalized == "unbound" || normalized == "disabled"
    }
}
