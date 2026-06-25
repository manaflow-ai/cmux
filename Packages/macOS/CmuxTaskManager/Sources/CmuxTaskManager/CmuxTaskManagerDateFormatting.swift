public import Foundation

/// Parses the snapshot `sampled_at` ISO-8601 timestamp and renders the
/// "updated at" clock time for the Task Manager header. Holds the two
/// Foundation formatters as stored state so they are built once and reused
/// across calls, replacing the former static cached formatters on the
/// `CmuxTaskManagerFormat` namespace.
///
/// Not `Sendable`: it stores reference-type Foundation formatters. Construct
/// and use one instance within a single isolation domain (e.g. one per
/// snapshot on the main actor).
public struct CmuxTaskManagerDateFormatting {
    private let isoFormatter = ISO8601DateFormatter()
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    public init() {}

    /// Parses an ISO-8601 timestamp string, returning `nil` for a missing or
    /// unparseable value.
    public func date(fromISO8601 raw: String?) -> Date? {
        guard let raw else { return nil }
        return isoFormatter.date(from: raw)
    }

    /// The medium-style clock time (no date component) for a sample instant.
    public func timeString(for date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
