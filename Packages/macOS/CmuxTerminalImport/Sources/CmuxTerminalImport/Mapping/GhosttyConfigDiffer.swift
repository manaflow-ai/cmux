import Foundation

/// Compares settings with a Ghostty config body to show what an import changes.
///
/// It only reads: the write goes through cmux's shared config writer, which
/// replaces a key's lines where the key first appeared.
public struct GhosttyConfigDiffer: Sendable {
    /// Creates a differ.
    public init() {}

    /// The per-key before and after for writing `settings` into `contents`.
    ///
    /// - Parameters:
    ///   - settings: The settings to be written, in order.
    ///   - contents: The current config body; empty when the file does not exist.
    ///     LF and CRLF files are both read without a stray `\r` in any value.
    /// - Returns: One change per setting.
    public func diff(_ settings: [GhosttyConfigSetting], against contents: String) -> GhosttyConfigDiff {
        let assignments = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in line.unicodeScalars.last == "\r" ? String(line.dropLast()) : line }
            .compactMap(Self.parse)
        return GhosttyConfigDiff(changes: settings.map { setting in
            GhosttyConfigDiff.Change(
                key: setting.key,
                oldValues: assignments.filter { $0.key == setting.key }.map(\.value),
                newValues: setting.values
            )
        })
    }

    /// The key and value of an active `key = value` line, or `nil` for comments and blanks.
    static func parse(_ line: String) -> (key: String, value: String)? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\u{FEFF}") {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }
}
