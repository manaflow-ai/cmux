import CmuxNextCompat
import CmuxNextWakeups
import os
import Testing

/// `BackgroundWork.task` and shutdown (plans/cmux-next/chrome-parity/p02-threads.md, task 012): async work states
/// its priority and shutdown behavior; shutdown cancels skip tasks, leaves continue tasks running and waits for
/// block tasks, as Chrome's TaskTracker (base/task/thread_pool/task_tracker.cc).
@Suite(.timeLimit(.minutes(1))) struct BackgroundWorkTaskTests {
    /// A one-way signal: bodies send, the test awaits (no polling, no sleep).
    struct Signal: Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }

        func send() { continuation.yield() }

        /// Returns after the next send; returns early (nil element) when the awaiting task is cancelled.
        func wait() async {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }

    /// An uptime clock that moves `stepMilliseconds` on every read.
    final class SteppingUptime: Sendable {
        let step: UInt64
        private let now = Mutex<UInt64>(0)

        init(stepMilliseconds: UInt64) { step = stepMilliseconds * 1_000_000 }

        func read() -> UInt64 {
            now.withLock { now in
                now += step
                return now
            }
        }
    }

    @Test func aBlockShutdownTaskFinishesBeforeShutdownReturns() async throws {
        let work = BackgroundWork(label: "test.task.block")
        let shutdownStarted = Signal()
        let release = Signal()
        let saved = OSAllocatedUnfairLock(initialState: false)
        let skipRunning = Signal()
        // Shutdown cancels this one first, which tells the block task that shutdown has started.
        let skip = work.task(.userVisible) {
            try await withTaskCancellationHandler {
                skipRunning.send()
                await release.wait()
                try Task.checkCancellation()
            } onCancel: {
                shutdownStarted.send()
            }
        }
        let save = work.task(.bestEffort, shutdown: .blockShutdown) {
            await shutdownStarted.wait()
            saved.withLock { $0 = true }
            return 7
        }
        await skipRunning.wait()
        await work.shutdown()
        #expect(saved.withLock { $0 }, "shutdown returned before the block-shutdown task finished")
        #expect(try await save.value == 7)
        await #expect(throws: CancellationError.self) { try await skip.value }
        #expect(work.registeredTaskCount == 0)
    }

    @Test func shutdownCancelsASkipTaskThatIsRunning() async throws {
        let work = BackgroundWork(label: "test.task.skip")
        let running = Signal()
        let never = Signal()
        let sawCancel = OSAllocatedUnfairLock(initialState: false)
        let skip = work.task(.userBlocking, shutdown: .skipOnShutdown) {
            running.send()
            // Returns when the task is cancelled: nothing ever sends.
            await never.wait()
            sawCancel.withLock { $0 = Task.isCancelled }
            try Task.checkCancellation()
        }
        await running.wait()
        await work.shutdown()
        await #expect(throws: CancellationError.self) { try await skip.value }
        #expect(sawCancel.withLock { $0 })
    }

    @Test func aStartedContinueTaskRunsOnAndShutdownDoesNotWaitForIt() async throws {
        let work = BackgroundWork(label: "test.task.continue")
        let running = Signal()
        let release = Signal()
        let task = work.task(.userVisible, shutdown: .continueOnShutdown) {
            running.send()
            await release.wait()
            return Task.isCancelled
        }
        await running.wait()
        // Returns while the task still waits for `release`: shutdown does not await it.
        await work.shutdown()
        release.send()
        #expect(try await task.value == false)
    }

    @Test(arguments: [ShutdownBehavior.skipOnShutdown, .continueOnShutdown])
    func afterShutdownANonBlockTaskThrowsCancellationErrorAndNeverRuns(behavior: ShutdownBehavior) async throws {
        let work = BackgroundWork(label: "test.task.refused")
        await work.shutdown()
        let ran = OSAllocatedUnfairLock(initialState: false)
        let task = work.task(.userBlocking, shutdown: behavior) {
            ran.withLock { $0 = true }
            return 1
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!ran.withLock { $0 })
        #expect(work.registeredTaskCount == 0)
    }

    @Test func afterShutdownABlockTaskStillRuns() async throws {
        let work = BackgroundWork(label: "test.task.late-save")
        await work.shutdown()
        let task = work.task(.bestEffort, shutdown: .blockShutdown) { 42 }
        #expect(try await task.value == 42)
        // A second shutdown waits for it too, and returns at once when nothing blocks.
        await work.shutdown()
        #expect(work.registeredTaskCount == 0)
    }

    @Test func noTaskStaysRegisteredAfterAThousandFinish() async throws {
        let work = BackgroundWork(label: "test.task.thousand")
        let behaviors: [ShutdownBehavior] = [.skipOnShutdown, .continueOnShutdown, .blockShutdown]
        let priorities = WorkPriority.allCases
        var tasks: [Task<Int, any Error>] = []
        for index in 0..<1_000 {
            tasks.append(work.task(priorities[index % priorities.count], shutdown: behaviors[index % behaviors.count]) {
                if index % 7 == 0 { throw CancellationError() }
                return index
            })
        }
        var sum = 0
        for task in tasks { sum += (try? await task.value) ?? 0 }
        #expect(sum == (0..<1_000).filter { $0 % 7 != 0 }.reduce(0, +))
        #expect(work.registeredTaskCount == 0)
        // Every block task was counted down: shutdown has nothing to wait for.
        await work.shutdown()
    }

    @Test func aTaskStartsAtItsStatedPriority() async throws {
        let work = BackgroundWork(label: "test.task.priority")
        // Detached: the caller's priority does not pass to it (a lower waiter does not escalate it either).
        let seen = try await Task(priority: .background) {
            try await work.task(.bestEffort) { Task.currentPriority }.value
        }.value
        #expect(WorkPriority(seen) == .bestEffort)
        let low = try await Task(priority: .background) {
            try await work.task(.userBlocking) { Task.currentPriority }.value
        }.value
        #expect(WorkPriority(low) == .userBlocking)
    }

    #if DEBUG
    @Test func aBlockShutdownItemThatRunsPast250msIsRecorded() async throws {
        // Every read of the clock moves it 300 ms: a block item's start and end are 300 ms apart.
        let uptime = SteppingUptime(stepMilliseconds: 300)
        let work = BackgroundWork(label: "test.task.overrun", uptimeNanos: { uptime.read() })
        #expect(work.blockShutdownOverruns.isEmpty)
        _ = try await work.task(.bestEffort, shutdown: .blockShutdown) { 1 }.value
        _ = try await work.task(.bestEffort, shutdown: .skipOnShutdown) { 1 }.value
        _ = try await work.task(.bestEffort, shutdown: .continueOnShutdown) { 1 }.value
        try await work.run(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) {}
        // Shutdown returns after the lane item's done step, which follows its record.
        await work.shutdown()
        let overruns = work.blockShutdownOverruns
        #expect(overruns.count == 2, "\(overruns)")
        #expect(overruns.allSatisfy { $0.site.hasPrefix("CmuxNextWakeupsTests/BackgroundWorkTaskTests.swift:") })
        #expect(overruns.allSatisfy { $0.duration == .milliseconds(300) })
        #expect(overruns.allSatisfy { $0.duration > BackgroundWork.blockShutdownLimit })
    }

    @Test func aShortBlockShutdownItemIsNotRecorded() async throws {
        let uptime = SteppingUptime(stepMilliseconds: 10)
        let work = BackgroundWork(label: "test.task.short", uptimeNanos: { uptime.read() })
        _ = try await work.task(.bestEffort, shutdown: .blockShutdown) { 1 }.value
        work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) {}
        await work.shutdown()
        #expect(work.blockShutdownOverruns.isEmpty)
    }
    #endif
}
