import CmuxNextDaemonService
import CmuxNextErrorJournal
import Foundation
import Testing

@testable import CmuxNextApp

/// The quit's error harvest (an `OSLogStore` read over the whole run, seconds after a long
/// session) never holds up the quit: the engines start to stop whatever the harvest does, and
/// once they stopped the harvest is cancelled and ends with what it read. Before, QuitCompletion
/// awaited the harvest before it stopped the engines, then after them with no limit on it.
@MainActor
@Suite struct QuitHarvestDeadlineTests {
    /// The steps in the order they ran.
    @MainActor final class Order {
        var steps: [String] = []
    }

    /// A source whose read finds one entry and then never ends until its task is cancelled (an
    /// OSLogStore read over a long run); cancelled, it returns what it found, as
    /// ``OSLogErrorSource`` does.
    nonisolated final class EndlessSource: ErrorHarvestSource {
        let id = "endless"
        /// Yields once the read found its entry.
        let reading: AsyncStream<Void>
        private let readingContinuation: AsyncStream<Void>.Continuation
        private let never: AsyncStream<Void>
        private let neverContinuation: AsyncStream<Void>.Continuation  // kept: `never` never finishes

        init() {
            (reading, readingContinuation) = AsyncStream.makeStream()
            (never, neverContinuation) = AsyncStream.makeStream()
        }

        func collect(after cursor: String?) async throws -> ErrorHarvest {
            let found = [ErrorEvent(source: "system:com.apple.WebKit", level: .error, message: "read before the quit ended it")]
            readingContinuation.yield()
            for await _ in never {}  // ends only when the harvest's task is cancelled
            return ErrorHarvest(events: found, cursor: "1")
        }
    }

    /// The quit harvest's log read grows with the run (seconds after hours) and the quit awaited
    /// it before AppKit's reply, under only the 15 s hang deadline (past it: `_exit(0)`, no
    /// applicationWillTerminate). The quit now cancels it when the engines stopped: the quit
    /// returns, and what the harvest read before is on disk.
    @Test(.timeLimit(.minutes(1))) func theQuitCancelsTheHarvestOnceTheEnginesStoppedAndKeepsWhatItRead() async throws {
        let directory = FileManager().temporaryDirectory.appendingPathComponent("quit-harvest-\(UUID().uuidString)")
        defer { try? FileManager().removeItem(at: directory) }
        let source = EndlessSource()
        let service = ErrorJournalService(journal: ErrorJournal(directory: directory), sources: [source])
        await QuitCompletion.run(.keep, remember: false, QuitSteps(
            remember: { _ in },
            prepareWindows: {},
            endLocalSessions: { _ in [] },
            confirmFailures: { _ in .quitAnyway },
            stopBrowserEngines: {
                // The engines stop while the harvest is in its endless read.
                for await _ in source.reading { break }
            },
            harvestErrors: { await service.stop() }
        ))
        // The next launch's journal reads what the cancelled harvest kept.
        let entries = await ErrorJournal(directory: directory).entries()
        #expect(entries.map(\.sample) == ["read before the quit ended it"], "the cancelled harvest did not write what it read")
    }

    @Test(.timeLimit(.minutes(1))) func theEnginesStopWhileTheHarvestStillRuns() async {
        let order = Order()
        let (engines, enginesStopped) = AsyncStream<Void>.makeStream()
        await QuitCompletion.run(.keep, remember: false, QuitSteps(
            remember: { _ in },
            prepareWindows: {},
            endLocalSessions: { _ in [] },
            confirmFailures: { _ in .quitAnyway },
            stopBrowserEngines: {
                order.steps.append("engines")
                enginesStopped.yield()
                enginesStopped.finish()
            },
            harvestErrors: {
                order.steps.append("harvest started")
                // The harvest ends only once the engines began to stop: before the fix the quit
                // waited for it first and never got there (the time limit fails the test).
                for await _ in engines {}
                order.steps.append("harvest ended")
            }
        ))
        // The harvest may start before or after the engines (a child task); it ends after them.
        #expect(order.steps.last == "harvest ended")
        #expect(order.steps.firstIndex(of: "engines").map { $0 < order.steps.count - 1 } == true)
    }
}
