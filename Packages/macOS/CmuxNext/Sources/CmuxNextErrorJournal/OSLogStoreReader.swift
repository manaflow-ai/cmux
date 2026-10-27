#if canImport(OSLog)
import Foundation
import OSLog

/// ``OSLogReading`` on `OSLogStore`, scoped to the current process. logd applies the level
/// predicate, so entries it rejects are never decoded in this process. macOS only: Linux has no
/// unified log (the Compat `Logger` writes to stderr there, as Chromium's `LOG()` does).
struct OSLogStoreReader: OSLogReading {
    func entries(since date: Date, levels: Set<OSLogRecord.Level>) throws -> [OSLogRecord] {
        guard !levels.isEmpty else { return [] }
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: date)
        let entries = try store.getEntries(at: position, matching: Self.predicate(levels))
        var records: [OSLogRecord] = []
        for case let entry as OSLogEntryLog in entries {
            records.append(OSLogRecord(date: entry.date, level: Self.level(entry.level), subsystem: entry.subsystem,
                                       category: entry.category, message: entry.composedMessage))
        }
        return records
    }

    /// The log store predicate for `levels` (`messageType`, as `log show --predicate` takes it), for
    /// example `messageType == "error" OR messageType == "fault"`.
    static func predicate(_ levels: Set<OSLogRecord.Level>) -> NSPredicate {
        let types = levels.map(\.messageType).sorted()
        return NSPredicate(format: types.map { _ in "messageType == %@" }.joined(separator: " OR "), argumentArray: types)
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
#endif
