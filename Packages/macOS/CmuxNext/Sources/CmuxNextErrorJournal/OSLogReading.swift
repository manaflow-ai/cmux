import Foundation

/// Reads this process's unified log (the seam ``OSLogErrorSource`` reads through; tests pass a
/// fake that applies the predicate as logd does).
protocol OSLogReading: Sendable {
    /// Hands `body` each entry at or after `date` that matches `predicate` (all when nil), oldest
    /// first, one at a time, until `body` returns false or the entries end. Entries after a false
    /// are never decoded: a reader stopped early (a cancelled harvest) costs only what it read.
    func read(since date: Date, matching predicate: NSPredicate?, _ body: (OSLogRecord) -> Bool) throws
}
