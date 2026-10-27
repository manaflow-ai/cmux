import Foundation

/// Reads this process's unified log (the seam ``OSLogErrorSource`` reads through; tests pass a
/// fake that filters as logd does).
protocol OSLogReading: Sendable {
    /// The entries at or after `date` whose level is one of `levels`, oldest first. The store
    /// filters, so an entry of another level is never decoded in this process.
    func entries(since date: Date, levels: Set<OSLogRecord.Level>) throws -> [OSLogRecord]
}
