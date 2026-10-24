@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextWakeups
import Dispatch
import os
import Testing

/// Quit honors ``ShutdownBehavior/blockShutdown``: after the session steps and before the engines stop it
/// waits, bounded, for the block-shutdown background work (store saves, the rollback keep), and for no
/// other item (threading-model.md, task traits).
@MainActor @Suite(.timeLimit(.minutes(1))) struct QuitBackgroundWorkTests {
    /// A real clock that reports each sleep: the bounded drain sleeps only while a block-shutdown item
    /// is still running, so the report is the point at which quit waits for it.
    struct ReportingClock: Clock {
        typealias Duration = Swift.Duration
        typealias Instant = ContinuousClock.Instant
        let onSleep: @Sendable () -> Void
        var now: Instant { ContinuousClock.now }
        var minimumResolution: Swift.Duration { ContinuousClock().minimumResolution }
        func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
            onSleep()
            try await ContinuousClock().sleep(until: deadline, tolerance: tolerance)
        }
    }

    @Test func quitStopsTheEnginesOnlyAfterTheBlockShutdownSaveAndNeverWaitsForOtherWork() async {
        let work = BackgroundWork(cpuWidth: 3, label: "test.quit.drain")
        let save = DispatchSemaphore(value: 0)
        let hang = DispatchSemaphore(value: 0)
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        // Work quit must not wait for: running items that hang until the test ends.
        work.post(.bestEffort, mayBlock: .cpu, shutdown: .continueOnShutdown) { hang.wait() }
        work.post(.bestEffort, mayBlock: .cpu, shutdown: .skipOnShutdown) { hang.wait() }
        // The promised save: it lands only once quit waits for it.
        work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) {
            save.wait()
            log.withLock { $0.append("saved") }
        }
        let clock = ReportingClock { save.signal() }
        let drained = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        await QuitCompletion.run(.keep, remember: false, QuitSteps(
            remember: { _ in },
            prepareWindows: { log.withLock { $0.append("windows") } },
            endLocalSessions: { _ in [] },
            confirmFailures: { _ in .quitAnyway },
            drainBackgroundWork: {
                let finished = await QuitCoordinator.drainBackgroundWork(work, limit: .seconds(30), clock: clock)
                drained.withLock { $0 = finished }
            },
            stopBrowserEngines: { log.withLock { $0.append("engines") } }
        ))
        #expect(log.withLock { $0 } == ["windows", "saved", "engines"])
        #expect(drained.withLock { $0 } == true)
        hang.signal()
        hang.signal()
    }

    @Test func aHungSaveHoldsQuitOnlyUntilItsBound() async {
        let work = BackgroundWork(label: "test.quit.drain.hung")
        let hang = DispatchSemaphore(value: 0)
        let (started, report) = AsyncStream.makeStream(of: Void.self)
        work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) {
            report.yield()
            hang.wait()
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let begin = ContinuousClock.now
        #expect(await QuitCoordinator.drainBackgroundWork(work, limit: .milliseconds(100)) == false)
        #expect(ContinuousClock.now - begin < .seconds(5))
        hang.signal()
    }
}
