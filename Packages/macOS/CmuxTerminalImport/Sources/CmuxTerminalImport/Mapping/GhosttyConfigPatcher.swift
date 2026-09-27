import Foundation

/// Writes settings into a Ghostty config body, keeping everything else intact.
///
/// Each written key ends up assigned exactly once: the first existing
/// assignment is replaced in place and later ones are removed, because
/// repeatable keys such as `font-family` would otherwise stack fallbacks.
/// Keys the config did not have are appended under a comment naming the source.
public struct GhosttyConfigPatcher: Sendable {
    /// Creates a patcher.
    public init() {}

    /// Applies settings to a config body.
    ///
    /// - Parameters:
    ///   - settings: The settings to write, in order.
    ///   - contents: The current config body; empty when the file does not exist.
    ///   - header: A comment line placed above appended settings.
    /// - Returns: The new body and a per-key change list.
    public func apply(
        _ settings: [GhosttyConfigSetting],
        to contents: String,
        header: String
    ) -> GhosttyConfigPatch {
        // A CRLF config stays CRLF, and no value carries a stray `\r` into the diff.
        let lineEnding = contents.range(of: "\r\n") != nil ? "\r\n" : "\n"
        var lines = contents.isEmpty ? [] : contents.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { line in
            line.unicodeScalars.last == "\r" ? String(line.dropLast()) : line
        }
        if lines.last == "" { lines.removeLast() }

        var changes: [GhosttyConfigPatch.Change] = []
        var appended: [String] = []
        for setting in settings {
            var oldValues: [String] = []
            var firstIndex: Int?
            var index = 0
            while index < lines.count {
                if let parsed = Self.parse(lines[index]), parsed.key == setting.key {
                    oldValues.append(parsed.value)
                    if firstIndex == nil {
                        firstIndex = index
                        lines[index] = "\(setting.key) = \(setting.value)"
                        index += 1
                    } else {
                        lines.remove(at: index)
                    }
                    continue
                }
                index += 1
            }
            if firstIndex == nil {
                appended.append("\(setting.key) = \(setting.value)")
            }
            changes.append(.init(key: setting.key, oldValues: oldValues, newValue: setting.value))
        }

        if !appended.isEmpty {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            lines.append("# \(header)")
            lines.append(contentsOf: appended)
        }
        let body = lines.joined(separator: lineEnding)
        return GhosttyConfigPatch(contents: body.isEmpty ? "" : body + lineEnding, changes: changes)
    }

    /// The key and value of an active `key = value` line, or `nil` for comments and blanks.
    static func parse(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }
}
