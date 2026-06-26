public import Foundation

/// Reads recent unified-log lines for a mobile diagnostics report.
public protocol MobileDiagnosticsOSLogReading: Sendable {
    /// Read recent log entries.
    ///
    /// - Parameters:
    ///   - since: The oldest timestamp to include.
    ///   - limit: Maximum number of entries returned.
    /// - Returns: Log entries in chronological order.
    func recentEntries(since: Date, limit: Int) throws -> [MobileDiagnosticsOSLogEntry]
}
