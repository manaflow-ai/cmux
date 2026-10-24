import CmuxNextErrorJournal
import Foundation
import os
import Testing

@testable import CmuxNextApp

/// The journal reads its sources at launch and at quit, never on a timer (idle-wakeups.md: an idle
/// app wakes for nothing). Before, a harvest ran every 300 s while the app ran (an `OSLogStore`
/// read: about 1.4 s, and 2.6 to 4.4 mW in its window with 20 hidden tabs, msg 2654), and the quit
/// read nothing: what the app logged after the last harvest was lost at every quit, since the next
/// launch cannot read an ended process's log store.
@MainActor
@Suite struct ErrorJournalServiceTests {
    /// A source that finds one new problem per read and reports each read.
    nonisolated final class CountingSource: ErrorHarvestSource {
        let id = "counting"
        let reads: AsyncStream<Int>
        private let continuation: AsyncStream<Int>.Continuation
        private let count = OSAllocatedUnfairLock(initialState: 0)

        init() { (reads, continuation) = AsyncStream.makeStream() }

        func collect(after cursor: String?) async throws -> ErrorHarvest {
            let read = count.withLock { count in
                count += 1
                return count
            }
            continuation.yield(read)
            return ErrorHarvest(events: [ErrorEvent(source: "acpmux", level: .error, message: "read \(read) found this")],
                                cursor: String(read))
        }
    }

    @Test func theQuitHarvestsWhatTheRunLogged() async throws {
        let directory = FileManager().temporaryDirectory.appendingPathComponent("error-journal-service-\(UUID().uuidString)")
        let source = CountingSource()
        let service = ErrorJournalService(journal: ErrorJournal(directory: directory), sources: [source])
        var reads = source.reads.makeAsyncIterator()
        service.start()
        #expect(await reads.next() == 1, "the launch harvest")
        await service.stop()

        // The next launch's journal reads both harvests from disk.
        let entries = await ErrorJournal(directory: directory).entries()
        #expect(entries.reduce(0) { $0 + $1.count } == 2, "the quit did not harvest, or did not write what it found")
    }
}
