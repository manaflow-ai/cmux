import Foundation

/// Parses the ISO8601 timestamps found on transcript lines.
///
/// Both Claude and Codex transcripts stamp lines like
/// `2026-06-12T05:07:51.103Z`; some lines omit fractional seconds.
struct TranscriptTimestampParser: Sendable {
    private let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private let plain = Date.ISO8601FormatStyle()

    /// Creates a timestamp parser.
    init() {}

    /// Parses an ISO8601 timestamp string.
    ///
    /// - Parameter raw: The timestamp text, possibly absent.
    /// - Returns: The parsed date, or `nil` when absent or malformed.
    func date(from raw: String?) -> Date? {
        guard let raw else { return nil }
        if let date = try? fractional.parse(raw) { return date }
        return try? plain.parse(raw)
    }
}
