import Foundation

/// Shared JSONL decoding helpers used by the transcript parsers.
///
/// A small value type (rather than free functions or a namespace enum) that
/// both ``ClaudeCodeTranscriptParser`` and ``CodexTranscriptParser`` construct
/// and hold, so per-line JSON decoding, re-serialization, and ISO8601 timestamp
/// parsing live in one place without crossing the "no free functions" rule.
struct TranscriptLineDecoder: Sendable {
    /// Creates a decoder.
    init() {}

    /// Parses one JSONL line into a dictionary, returning `nil` on any error or
    /// for a blank line.
    func object(from line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Re-serializes a JSON value to a compact, key-sorted string. Strings pass
    /// through unchanged; values that are not valid JSON return `nil`.
    func jsonString(from value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Parses an ISO8601 timestamp string (with or without fractional seconds),
    /// or `nil` when the value is missing or unparseable.
    ///
    /// Formatters are constructed per call: `ISO8601DateFormatter` is not
    /// `Sendable`, so it cannot be a shared `static let` under Swift 6, and a
    /// transcript holds at most a few thousand lines so the cost is negligible.
    func date(from value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: string) { return parsed }
        return ISO8601DateFormatter().date(from: string)
    }
}
