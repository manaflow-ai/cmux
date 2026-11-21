import CmuxNextErrorJournal
import Foundation
import os
import Testing

@testable import CmuxNextApp

/// Idle CPU (2026-11-10): an app at rest read every journal source, the unified log included, at
/// launch and then every 300 s; each read of the log cost its `OSLogService.xpc` about 26 CPU
/// seconds on a Mac with a large log store (8.6 % of a core over 15 hours, in three apps). The app
/// at rest reads no source: only a demand (`errors.list`, Copy Logs) does.
///
/// Sizes do not apply here: the cost is per read of the log store, not per workspace or tab.
@Suite struct ErrorJournalIdleTests {
    /// A source that counts its reads.
    private final class CountingSource: ErrorHarvestSource, Sendable {
        let id = "counting"
        private let count = OSAllocatedUnfairLock(initialState: 0)

        var reads: Int { count.withLock { $0 } }

        func collect(after cursor: String?) async throws -> ErrorHarvest {
            count.withLock { $0 += 1 }
            return ErrorHarvest(events: [], cursor: nil)
        }
    }

    @Test @MainActor func theAppAtRestReadsNoSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("error-journal-idle-\(UUID().uuidString)")
        let source = CountingSource()
        // The fix deleted `start()` (it began the read at launch and the 300 s loop), and with it
        // the call here: the service that the app makes at launch reads nothing.
        let service = ErrorJournalService(journal: ErrorJournal(directory: directory), sources: [source])
        #expect(service.sources.count == 1)

        // A read at launch starts in the first milliseconds: half a second with none is none.
        for _ in 0..<50 where source.reads == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(source.reads == 0, "the app read its journal sources \(source.reads) time(s) with no demand")
    }
}
