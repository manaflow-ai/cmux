import Foundation

/// Reads this process's unified log (the seam ``OSLogErrorSource`` reads through; tests pass a
/// fake that applies the predicate as logd does).
protocol OSLogReading: Sendable {
    /// The entries at or after `date` that match `predicate` (all when nil), oldest first.
    func entries(since date: Date, matching predicate: NSPredicate?) throws -> [OSLogRecord]
}
