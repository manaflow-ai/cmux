import Foundation
import CMUXSettingsCore

extension CMUXCLI {
    struct CLIShortcut: Equatable {
        let strokes: [CLIShortcutStroke]
        let isUnbound: Bool

        static let unbound = CLIShortcut(strokes: [], isUnbound: true)

        var configString: String {
            if isUnbound {
                return "none"
            }
            return strokes.map(\.configString).joined(separator: ", ")
        }

        static func parseJSONValue(
            _ value: Any,
            action: CmuxSettingsRegistry.ShortcutActionDefinition
        ) throws -> CLIShortcut {
            if value is NSNull {
                return .unbound
            }
            if let string = value as? String {
                return try parse(string, action: action)
            }
            if let strings = value as? [String] {
                return try parse(strokes: strings, action: action)
            }
            throw CLIError(message: "Shortcut for \(action.action) must be a string, string array, or null")
        }

        static func parse(_ raw: String, action: CmuxSettingsRegistry.ShortcutActionDefinition) throws -> CLIShortcut {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["", "none", "clear", "unbound", "disabled"].contains(trimmed.lowercased()) {
                return .unbound
            }
            if let value = CmuxSettingsRegistry.parseJSONLiteral(trimmed) {
                return try parseJSONValue(value, action: action)
            }
            return try parse(strokes: splitChordString(trimmed), action: action)
        }

        static func parse(strokes rawStrokes: [String], action: CmuxSettingsRegistry.ShortcutActionDefinition) throws -> CLIShortcut {
            guard (1...2).contains(rawStrokes.count) else {
                throw CLIError(message: "Shortcut for \(action.action) must have one stroke or a two-stroke chord")
            }
            let strokes = try rawStrokes.map { try CLIShortcutStroke.parse($0) }
            var shortcut = CLIShortcut(strokes: strokes, isUnbound: false)
            if action.action == "showHideAllWindows" {
                guard shortcut.strokes.count == 1 else {
                    throw CLIError(message: "Global hotkey shortcut cannot be a chord")
                }
                guard shortcut.strokes[0].hasModifier else {
                    throw CLIError(message: "Global hotkey shortcut must include a modifier")
                }
            }
            if action.usesNumberedDigitMatching {
                guard let last = shortcut.strokes.last, last.isDigit else {
                    throw CLIError(message: "\(action.action) shortcut must use a digit 1-9")
                }
                shortcut = CLIShortcut(
                    strokes: Array(shortcut.strokes.dropLast()) + [last.normalizedNumberedDigit],
                    isUnbound: false
                )
            }
            return shortcut
        }

        private static func splitChordString(_ raw: String) -> [String] {
            var strokes: [String] = []
            var strokeStart = raw.startIndex
            var index = raw.startIndex
            while index < raw.endIndex {
                guard raw[index] == "," else {
                    index = raw.index(after: index)
                    continue
                }

                let next = raw.index(after: index)
                guard next < raw.endIndex, raw[next].isWhitespace else {
                    index = next
                    continue
                }

                strokes.append(String(raw[strokeStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                var nextStrokeStart = next
                while nextStrokeStart < raw.endIndex, raw[nextStrokeStart].isWhitespace {
                    nextStrokeStart = raw.index(after: nextStrokeStart)
                }
                strokeStart = nextStrokeStart
                index = nextStrokeStart
            }

            strokes.append(String(raw[strokeStart..<raw.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines))
            return strokes
        }

        func conflicts(
            with other: CLIShortcut,
            lhsNumbered: Bool,
            rhsNumbered: Bool
        ) -> Bool {
            guard !isUnbound, !other.isUnbound else { return false }
            switch (strokes.count, other.strokes.count) {
            case (1, 1):
                return strokes[0].conflicts(with: other.strokes[0], lhsNumbered: lhsNumbered, rhsNumbered: rhsNumbered)
            case (2, 2):
                return strokes[0].exactlyConflicts(with: other.strokes[0]) &&
                    strokes[1].conflicts(with: other.strokes[1], lhsNumbered: lhsNumbered, rhsNumbered: rhsNumbered)
            case (2, 1):
                return strokes[0].conflicts(with: other.strokes[0], lhsNumbered: false, rhsNumbered: rhsNumbered)
            case (1, 2):
                return strokes[0].conflicts(with: other.strokes[0], lhsNumbered: lhsNumbered, rhsNumbered: false)
            default:
                return false
            }
        }
    }

    struct CLIShortcutStroke: Equatable {
        let key: String
        let command: Bool
        let shift: Bool
        let option: Bool
        let control: Bool

        var hasModifier: Bool { command || shift || option || control }
        var isDigit: Bool { Int(key).map { (1...9).contains($0) } ?? false }
        var normalizedNumberedDigit: CLIShortcutStroke {
            CLIShortcutStroke(key: "1", command: command, shift: shift, option: option, control: control)
        }

        var configString: String {
            var tokens: [String] = []
            if command { tokens.append("cmd") }
            if shift { tokens.append("shift") }
            if option { tokens.append("opt") }
            if control { tokens.append("ctrl") }
            tokens.append(displayKey)
            return tokens.joined(separator: "+")
        }

        var displayKey: String {
            switch key {
            case "\r": return "return"
            case "\t": return "tab"
            case " ": return "space"
            case "\u{1B}": return "escape"
            case "←": return "left"
            case "→": return "right"
            case "↑": return "up"
            case "↓": return "down"
            default: return key
            }
        }

        static func parse(_ raw: String) throws -> CLIShortcutStroke {
            let pieces = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "+", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !pieces.isEmpty else {
                throw CLIError(message: "Shortcut is empty")
            }
            var command = false
            var shift = false
            var option = false
            var control = false
            var keyPieces: [String] = []
            for piece in pieces {
                switch piece.lowercased() {
                case "cmd", "command", "⌘":
                    command = true
                case "shift", "⇧":
                    shift = true
                case "option", "opt", "alt", "⌥":
                    option = true
                case "ctrl", "control", "^":
                    control = true
                default:
                    keyPieces.append(piece)
                }
            }
            guard keyPieces.count == 1, let rawKey = keyPieces.first else {
                throw CLIError(message: "Shortcut '\(raw)' must contain exactly one key")
            }
            guard command || shift || option || control else {
                throw CLIError(message: "Shortcut '\(raw)' must include a modifier")
            }
            guard let key = normalizedKey(rawKey) else {
                throw CLIError(message: "Shortcut key '\(rawKey)' is not supported")
            }
            return CLIShortcutStroke(key: key, command: command, shift: shift, option: option, control: control)
        }

        static func normalizedKey(_ raw: String) -> String? {
            if raw.isEmpty {
                return nil
            }
            switch raw.lowercased() {
            case "return", "enter":
                return "\r"
            case "tab":
                return "\t"
            case "space", "spacebar":
                return " "
            case "left", "arrowleft":
                return "←"
            case "right", "arrowright":
                return "→"
            case "up", "arrowup":
                return "↑"
            case "down", "arrowdown":
                return "↓"
            case "escape", "esc":
                return "\u{1B}"
            default:
                return raw.count == 1 ? raw.lowercased() : nil
            }
        }

        func conflicts(
            with other: CLIShortcutStroke,
            lhsNumbered: Bool,
            rhsNumbered: Bool
        ) -> Bool {
            if lhsNumbered || rhsNumbered {
                guard isDigit, other.isDigit else { return false }
                return command == other.command &&
                    shift == other.shift &&
                    option == other.option &&
                    control == other.control
            }
            return exactlyConflicts(with: other)
        }

        func exactlyConflicts(with other: CLIShortcutStroke) -> Bool {
            key == other.key &&
                command == other.command &&
                shift == other.shift &&
                option == other.option &&
                control == other.control
        }
    }
}
