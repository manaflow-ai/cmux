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

        func read(since date: Date, matching predicate: NSPredicate?, _ body: (OSLogRecord) -> Bool) throws {
            delivered = 0
            for record in records where record.date >= date && (predicate?.evaluate(with: ["messageType": record.level.messageType,
                                                                                           "subsystem": record.subsystem]) ?? true) {
                delivered += 1
                guard body(record) else { return }
            }
        }
    }

    /// A log store over a long run: hands entries one by one, and cancels the reading task right
    /// before it hands entry `cancelAt` (as the quit's cancellation arrives in the middle of a read).
    private final class LongLog: OSLogReading, @unchecked Sendable {
        // Test fake: written by the one reading task, read after that read returned.
        private(set) var delivered = 0
        let start: Date
        let cancelAt: Int

        init(start: Date, cancelAt: Int) {
            self.start = start
            self.cancelAt = cancelAt
        }

        func read(since date: Date, matching predicate: NSPredicate?, _ body: (OSLogRecord) -> Bool) throws {
            var index = 0
            while true {  // a log longer than any read: only the body ends it
                index += 1
                if index == cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
                let record = OSLogRecord(date: start + Double(index), level: .error, subsystem: "com.apple.WebKit",
                                         category: "Loading", message: "entry \(index)")
                guard record.date >= date else { continue }
                delivered += 1
                guard body(record) else { return }
            }
        }
    }

    /// The quit and `errors.list` read the log from the cursor, and that read grew with the run
    /// (the quit's covers the whole run since the launch harvest, about 1.4 s per 300 s of a busy
    /// one): the source read every entry before it returned, whatever its task said. A cancelled
    /// read now stops at the next entry and returns what it read, with the cursor at its last
    /// entry, so a caller's limit decides the wait and the next read goes on from there.
    @Test(.timeLimit(.minutes(1))) func aCancelledReadReturnsWhatItReadWithTheCursorAtItsLastEntry() async throws {
        let launch = Date(timeIntervalSince1970: 1_000)
        let log = LongLog(start: launch, cancelAt: 4)
        let source = OSLogErrorSource(processID: 7, launchDate: launch, reader: log)
        // Its own task: the cancellation is the read's, not the test's.
        let harvest = try await Task { try await source.collect(after: nil) }.value

        #expect(harvest.events.map(\.message) == ["entry 1", "entry 2", "entry 3"])
        #expect(harvest.cursor == "7:\(Int64((launch.timeIntervalSince1970 + 3) * 1000))")
        #expect(harvest.more == false)
        #expect(log.delivered == 4, "the read went on after its task was cancelled")
    }

    /// A run with more framework errors than one read's bound kept only the first ``OSLogErrorSource/batchLimit``
    /// at quit. A read now stops at the bound with ``ErrorHarvest/more``, and the journal reads the
    /// rest from the cursor in the same harvest.
    @Test func aRunPastTheReadBoundIsHarvestedWhole() async throws {
        let launch = Date(timeIntervalSince1970: 1_000)
        let total = OSLogErrorSource.batchLimit + 10
        let log = FakeLog(records: (1...total).map {
            OSLogRecord(date: launch + Double($0) / 100, level: .error, subsystem: "com.apple.WebKit", category: "Loading",
                        message: "distinct \($0)")
        })
        let directory = FileManager().temporaryDirectory.appendingPathComponent("oslog-batches-\(UUID().uuidString)")
        defer { try? FileManager().removeItem(at: directory) }
        let journal = ErrorJournal(directory: directory)
        let found = await journal.harvest([OSLogErrorSource(processID: 7, launchDate: launch, reader: log)])
        #expect(found["oslog"] == total, "one harvest kept \(found["oslog"] ?? 0) of \(total) errors")
    }

    @Test func theSourceAsksTheLogStoreForErrorsAndFaultsOnly() async throws {
        let launch = Date(timeIntervalSince1970: 1_000)
        var records = (0..<1_000).map { OSLogRecord(date: launch + Double($0) / 100, level: .info, subsystem: "org.chromium",
                                                    category: "net", message: "info \($0)") }
        records.append(OSLogRecord(date: launch + 20, level: .error, subsystem: "com.cmuxterm.app", category: "acp", message: "it failed"))
        records.append(OSLogRecord(date: launch + 21, level: .fault, subsystem: "com.apple.WebKit", category: "Loading", message: "it broke"))
        let log = FakeLog(records: records)
        let source = OSLogErrorSource(processID: 7, launchDate: launch, reader: log)

        let harvest = try await source.collect(after: nil)

        #expect(harvest.events.map(\.message) == ["it failed", "it broke"])
        #expect(log.delivered == 2, "the log store decoded \(log.delivered) entries for 2 errors and faults")
    }

    /// A page's console errors reach the journal when they happen (``ConsoleErrorCapture`` records
    /// them itself, so a crash loses none and no harvest is needed for them). The unified log still
    /// has them for Console.app, so the harvest must leave them out: read again from the log, each
    /// would count twice.
    @Test func theSourceLeavesPageConsoleLinesToTheCapture() async throws {
        let launch = Date(timeIntervalSince1970: 1_000)
        let log = FakeLog(records: [
            OSLogRecord(date: launch + 1, level: .error, subsystem: ConsoleErrorCapture.subsystem, category: "settings",
                        message: "theme missing"),
            OSLogRecord(date: launch + 2, level: .error, subsystem: "com.cmuxterm.app", category: "acp", message: "it failed"),
        ])
        let harvest = try await OSLogErrorSource(processID: 7, launchDate: launch, reader: log).collect(after: nil)
        #expect(harvest.events.map(\.message) == ["it failed"])
        #expect(log.delivered == 1, "the log store decoded the page console line the capture already recorded")
    }

    /// cmux's own reported errors reach the journal when they happen (``ErrorReporter`` records
    /// them itself); the harvest leaves their subsystem out, as it does the page consoles', so each
    /// counts once. Framework errors logged in this process are still harvested.
    @Test func theSourceLeavesReportedLinesToTheReporter() async throws {
        let launch = Date(timeIntervalSince1970: 1_000)
        let log = FakeLog(records: [
            OSLogRecord(date: launch + 1, level: .error, subsystem: ErrorReporter.subsystem, category: "app.quit",
                        message: "quit setting write failed"),
            OSLogRecord(date: launch + 2, level: .fault, subsystem: "com.apple.WebKit", category: "Loading", message: "it broke"),
        ])
        let harvest = try await OSLogErrorSource(processID: 7, launchDate: launch, reader: log).collect(after: nil)
        #expect(harvest.events.map(\.message) == ["it broke"])
        #expect(log.delivered == 1, "the log store decoded the reported line the reporter already recorded")
    }
}
