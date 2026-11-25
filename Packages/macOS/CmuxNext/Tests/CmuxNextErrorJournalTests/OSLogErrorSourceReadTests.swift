@testable import CmuxNextErrorJournal
import Foundation
import Testing

/// Idle power (msg 2654): with 20 hidden tabs the app's energy rose from about 0.24 to 2.6 to
/// 4.4 mW in some 60 s windows on cmux14. A stack sample inside one such window showed the
/// error-journal harvest (every 300 s) for the whole 10 s: `OSLogErrorSource` read every entry
/// of this process's log since the last harvest, at every level, decoded each one over XPC from
/// logd, and kept only errors and faults. Chromium logs much at info level. The source must ask
/// the log store for errors and faults only, so logd filters them (on cmux14, 2002 entries in
/// 5.2 s became 2 entries in 1.4 s).
@Suite struct OSLogErrorSourceReadTests {
    /// A log store that applies the source's predicate as logd does, and counts what it hands back.
    private final class FakeLog: OSLogReading, @unchecked Sendable {
        // Test fake: written once before the source runs, then read by it on one task.
        var records: [OSLogRecord]
        private(set) var delivered = 0

        init(records: [OSLogRecord]) { self.records = records }

        func entries(since date: Date, matching predicate: NSPredicate?) throws -> [OSLogRecord] {
            let found = records.filter { record in
                record.date >= date && (predicate?.evaluate(with: ["messageType": record.level.messageType]) ?? true)
            }
            delivered = found.count
            return found
        }
    }

    @Test func theSourceAsksTheLogStoreForErrorsAndFaultsOnly() async throws {
        let launch = Date(timeIntervalSince1970: 1_000)
        var records = (0..<1_000).map { OSLogRecord(date: launch + Double($0) / 100, level: .info, subsystem: "org.chromium",
                                                    category: "net", message: "info \($0)") }
        records.append(OSLogRecord(date: launch + 20, level: .error, subsystem: "com.cmuxterm.app", category: "acp", message: "it failed"))
        records.append(OSLogRecord(date: launch + 21, level: .fault, subsystem: "com.apple.WebKit", category: "Loading", message: "it broke"))
        let log = FakeLog(records: records)
        let source = OSLogErrorSource(processID: 7, launchDate: launch, reader: log, now: { launch + 30 })

        let harvest = try await source.collect(after: nil)

        #expect(harvest.events.map(\.message) == ["it failed", "it broke"])
        #expect(log.delivered == 2, "the log store decoded \(log.delivered) entries for 2 errors and faults")
    }

    /// Review of #40582: with no read at rest, one window can hold more entries than one read keeps
    /// (an app at rest for a night while one error repeats). The read kept the OLDEST 5000 and left
    /// the newer ones to the next demand, so Copy Logs showed old errors first and each demand
    /// decoded the rest of the window again. It keeps the newest and does not come back.
    @Test func aReadOfMoreEntriesThanItKeepsGivesTheNewestAndDoesNotComeBack() async throws {
        let launch = Date(timeIntervalSince1970: 1_000)
        let records = (0..<5_003).map { OSLogRecord(date: launch + 1 + Double($0) / 100, level: .error, subsystem: "com.cmuxterm.app",
                                                    category: "acp", message: "error \($0)") }
        let log = FakeLog(records: records)
        let source = OSLogErrorSource(processID: 7, launchDate: launch, reader: log, now: { launch + 120 })

        let first = try await source.collect(after: nil)
        let second = try await source.collect(after: first.cursor)

        #expect(first.events.count == 5_000)
        #expect(first.events.last?.message == "error 5002", "the read kept the oldest entries: its last one is \(first.events.last?.message ?? "none")")
        #expect(second.events.isEmpty, "the next demand read \(second.events.count) older entries again")
    }
}
