import Foundation
import OSLog

/// ``OSLogReading`` on `OSLogStore`, scoped to the current process. logd applies the predicate,
/// so entries it rejects are never decoded in this process.
struct OSLogStoreReader: OSLogReading {
    func entries(since date: Date, matching predicate: NSPredicate?) throws -> [OSLogRecord] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: date)
        let entries = try predicate.map { try store.getEntries(at: position, matching: $0) } ?? store.getEntries(at: position)
        var records: [OSLogRecord] = []
        for case let entry as OSLogEntryLog in entries {
            records.append(OSLogRecord(date: entry.date, level: Self.level(entry.level), subsystem: entry.subsystem,
                                       category: entry.category, message: entry.composedMessage))
        }
        return records
    }

    private static func level(_ level: OSLogEntryLog.Level) -> OSLogRecord.Level {
        switch level {
        case .debug: .debug
        case .info: .info
        case .error: .error
        case .fault: .fault
        default: .notice
        }
    }
}
