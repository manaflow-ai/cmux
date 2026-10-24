import Foundation
import OSLog

/// ``OSLogReading`` on `OSLogStore`, scoped to the current process. logd applies the predicate,
/// so entries it rejects are never decoded in this process; the store's sequence is enumerated
/// lazily, so entries after the one `body` stops at are never decoded either.
struct OSLogStoreReader: OSLogReading {
    func read(since date: Date, matching predicate: NSPredicate?, _ body: (OSLogRecord) -> Bool) throws {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: date)
        let entries = try predicate.map { try store.getEntries(at: position, matching: $0) } ?? store.getEntries(at: position)
        for case let entry as OSLogEntryLog in entries {
            let record = OSLogRecord(date: entry.date, level: Self.level(entry.level), subsystem: entry.subsystem,
                                     category: entry.category, message: entry.composedMessage)
            guard body(record) else { return }
        }
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
