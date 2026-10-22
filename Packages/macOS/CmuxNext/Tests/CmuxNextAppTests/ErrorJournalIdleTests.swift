@testable import CmuxNextApp
import CmuxNextErrorJournal
import Foundation
import Testing

/// Idle cost (plans/cmux-next/speed-of-sound-DESIGN.md, floor 0 at idle): the journal's periodic
/// harvest read the unified log through OSLogService every 300 s, and that one read cost the tree
/// 2.6 % CPU over a 60 s idle window on cmux20 (fleet step f4441a71, 20 idle terminals: 3.34 %
/// total, OSLogService 2.58 %). A running app that nobody asks for errors and that stays in front
/// must not harvest at all: no read at launch, no timer.
@MainActor
@Suite struct ErrorJournalIdleTests {
    /// A source that counts how often the journal reads it.
    private actor CountingSource: ErrorHarvestSource {
        nonisolated let id = "counting"
        private(set) var reads = 0

        func collect(after cursor: String?) async throws -> ErrorHarvest {
            reads += 1
            return ErrorHarvest(events: [], cursor: cursor)
        }
    }

    @Test func aStartedJournalReadsNothingAndArmsNoTimerWhileNothingAsks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("errors-idle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = CountingSource()
        let clock = ManualClock()
        let service = ErrorJournalService(journal: ErrorJournal(directory: folder), sources: [source], clock: clock)

        service.start()
        // A periodic harvest reads its sources and then goes to sleep on the clock; an idle
        // journal never sleeps on it.
        await #expect(throws: ManualClock.NoSleeper.self) { try await clock.waitForSleeper() }
        clock.advance(by: .seconds(3_600))
        #expect(await source.reads == 0)
        await service.stop()
    }
}

extension ErrorJournalIdleTests {
    @Test func leavingTheAppHarvestsAtMostOncePerSpacing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("errors-leave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = CountingSource()
        let clock = ManualClock()
        let service = ErrorJournalService(journal: ErrorJournal(directory: folder), sources: [source], clock: clock)

        await service.appDidResignActive()?.value
        #expect(await source.reads == 1)
        #expect(!service.isHarvesting)
        clock.advance(by: .seconds(60))
        #expect(service.appDidResignActive() == nil)
        clock.advance(by: ErrorJournalService.harvestSpacing)
        await service.appDidResignActive()?.value
        #expect(await source.reads == 2)
        await service.stop()
    }
}
