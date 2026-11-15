@testable import CmuxNextErrorJournal
import Foundation
import os
import Testing

/// Idle CPU (2026-11-10): three apps at rest for 15 hours each had an `OSLogService.xpc` at 8.6 %
/// of a core over its whole life, about 26 CPU seconds in each read of the unified log, one read
/// every 300 s. One `OSLogStore` query costs the same for a 5 s window and for a 24 h window
/// (2.0 s wall on aws-m4pro-5, macOS 26.5.2, a 2.1 GB log store), so a read is paid for by a demand
/// (`errors.list`, Copy Logs) only, one at a time, for a window with an end.
///
/// Sizes do not apply here: the cost is per read of the log store, not per workspace or tab.
@Suite struct ErrorJournalDemandReadTests {
    /// A log store with no entries that keeps the start of every window it was asked for.
    private final class RecordingLog: OSLogReading, Sendable {
        private let asked = OSAllocatedUnfairLock(initialState: [Date]())

        var windows: [Date] { asked.withLock { $0 } }

        func entries(since date: Date, matching predicate: NSPredicate?) throws -> [OSLogRecord] {
            asked.withLock { $0.append(date) }
            return []
        }
    }

    /// A source whose read takes 100 ms and that counts how many reads run at the same time.
    private final class SlowSource: ErrorHarvestSource, Sendable {
        let id = "slow"
        private let counts = OSAllocatedUnfairLock(initialState: (running: 0, mostAtOnce: 0, reads: 0))

        var mostAtOnce: Int { counts.withLock { $0.mostAtOnce } }
        var reads: Int { counts.withLock { $0.reads } }

        func collect(after cursor: String?) async throws -> ErrorHarvest {
            counts.withLock {
                $0.running += 1
                $0.reads += 1
                $0.mostAtOnce = max($0.mostAtOnce, $0.running)
            }
            try? await Task.sleep(for: .milliseconds(100))
            counts.withLock { $0.running -= 1 }
            return ErrorHarvest(events: [], cursor: nil)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("error-journal-demand-\(UUID().uuidString)")
    }

    @Test func aDemandReadsTheLastThreeDaysOfTheLogAtMost() async throws {
        let log = RecordingLog()
        // Copy Logs shows the problems of the last 3 days: no demand needs more of the log.
        let source = OSLogErrorSource(processID: 7, launchDate: Date().addingTimeInterval(-30 * 86_400), reader: log)

        _ = try await source.collect(after: nil)

        let start = try #require(log.windows.first)
        let age = Date().timeIntervalSince(start)
        #expect(age <= 3 * 86_400 + 60, "the first demand of an app that is 30 days old asked for \(Int(age)) s of the log")
    }

    @Test func theNextDemandStartsWhereTheLastOneEnded() async throws {
        let log = RecordingLog()
        // An app that is one hour old and wrote no error: the first demand finds nothing.
        let source = OSLogErrorSource(processID: 7, launchDate: Date().addingTimeInterval(-3_600), reader: log)

        let first = try await source.collect(after: nil)
        _ = try await source.collect(after: first.cursor)

        #expect(log.windows.count == 2)
        let again = Date().timeIntervalSince(try #require(log.windows.last))
        #expect(again <= 60, "the second demand asked again for \(Int(again)) s of the log that the first one had read")
    }

    @Test func aDemandAfterALongRestReadsTheNewestPartOfALogFile() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("daemon.log")
        try Data("2026-01-01T00:00:00Z INFO start\n".utf8).write(to: log)
        let source = LogFileErrorSource(url: log, source: "x", maxReadBytes: 64)
        let first = try await source.collect(after: nil)
        // With no read at rest the file grows by more than one read between two demands.
        var grown = try String(contentsOf: log, encoding: .utf8)
        for index in 0..<10 { grown += "2026-01-01T00:00:0\(index)Z ERROR old problem \(index)\n" }
        grown += "2026-01-02T00:00:00Z ERROR newest problem\n"
        try Data(grown.utf8).write(to: log)

        let second = try await source.collect(after: first.cursor)

        #expect(second.events.map(\.message).last?.contains("newest problem") == true,
                "the demand read \(second.events.map(\.message)) and left the newest line for a later read")
        let third = try await source.collect(after: second.cursor)
        #expect(third.events.isEmpty, "the next demand read old lines again or late")
    }

    @Test func twoDemandsNeverReadAtTheSameTime() async throws {
        let journal = ErrorJournal(directory: temporaryDirectory())
        let source = SlowSource()

        async let first = journal.harvest([source])
        async let second = journal.harvest([source])
        _ = await (first, second)

        #expect(source.mostAtOnce == 1, "\(source.mostAtOnce) reads of one source ran at the same time")
        #expect(source.reads == 2, "each demand gets a read that started after it")
    }
}
