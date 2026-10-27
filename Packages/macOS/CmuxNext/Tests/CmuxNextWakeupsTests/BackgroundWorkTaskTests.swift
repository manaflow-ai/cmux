import CmuxNextCompat
@testable import CmuxNextWakeups
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

    @Test func aBlockItemIsTakenUntilShutdownReturnsAndRefusedAfter() async throws {
        let work = BackgroundWork(label: "test.task.late-save")
        work.beginShutdown()
        // Shutdown has begun, not returned: a block-shutdown save is still taken, and shutdown waits for it.
        let early = work.task(.bestEffort, shutdown: .blockShutdown) { 42 }
        await work.shutdown()
        #expect(try await early.value == 42)
        // Nothing would wait for these any more: each is refused and never runs (Chrome DCHECKs such a post).
        let ran = OSAllocatedUnfairLock(initialState: false)
        let late = work.task(.bestEffort, shutdown: .blockShutdown) {
            ran.withLock { $0 = true }
            return 1
        }
        await #expect(throws: CancellationError.self) { try await late.value }
        await #expect(throws: CancellationError.self) {
            try await work.run(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { ran.withLock { $0 = true } }
        }
        work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { ran.withLock { $0 = true } }
        #expect(!ran.withLock { $0 })
        #expect(work.registeredTaskCount == 0)
        #if DEBUG
        let sites = work.blockShutdownLatePosts
        #expect(sites.count == 3, "\(sites)")
        #expect(sites.allSatisfy { $0.hasPrefix("CmuxNextWakeupsTests/BackgroundWorkTaskTests.swift:") })
        #endif
        // A second shutdown has nothing to wait for.
        await work.shutdown()
    }

    @Test(arguments: [ShutdownBehavior.skipOnShutdown, .continueOnShutdown])
    func aTaskThatHadNotStartedWhenShutdownBeganNeverRunsOp(behavior: ShutdownBehavior) async throws {
        let entered = Signal()
        let gate = Signal()
        // The body stops before its shutdown check until the gate opens: the task is registered, not started.
        let hooks = BackgroundWork.TaskHooks(beforeBody: {
            entered.send()
            await gate.wait()
        }, attach: { $0() })
        let work = BackgroundWork(cpuWidth: 1, label: "test.task.unstarted", onQueued: { _, _ in }, uptimeNanos: nil,
                                  taskHooks: hooks)
        let ran = OSAllocatedUnfairLock(initialState: false)
        let task = work.task(.userVisible, shutdown: behavior) {
            ran.withLock { $0 = true }
            return 1
        }
        await entered.wait()
        // Neither behavior is awaited: shutdown returns while the body still waits at the gate.
        await work.shutdown()
        gate.send()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!ran.withLock { $0 })
        #expect(work.registeredTaskCount == 0)
    }

    @Test func aStartedSkipTaskThatShutdownMetBeforeItsCancelWasSetIsCancelledWhenItIs() async throws {
        let attachLater = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        // The task gets its cancel only when the test says so: shutdown comes in between.
        let hooks = BackgroundWork.TaskHooks(beforeBody: {}, attach: { attachNow in
            attachLater.withLock { $0 = attachNow }
        })
        let work = BackgroundWork(cpuWidth: 1, label: "test.task.attach", onQueued: { _, _ in }, uptimeNanos: nil,
                                  taskHooks: hooks)
        let running = Signal()
        let never = Signal()
        let sawCancel = OSAllocatedUnfairLock(initialState: false)
        let task = work.task(.userVisible, shutdown: .skipOnShutdown) {
            running.send()
            // Returns when the task is cancelled: nothing ever sends.
            await never.wait()
            sawCancel.withLock { $0 = Task.isCancelled }
            try Task.checkCancellation()
        }
        // `op` runs: the body passed its shutdown check before shutdown began.
        await running.wait()
        await work.shutdown()
        // Shutdown found no cancel to call; the task still runs.
        #expect(work.registeredTaskCount == 1)
        let attach = try #require(attachLater.withLock { $0 })
        attach()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(sawCancel.withLock { $0 })
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

    @Test(arguments: WorkPriority.allCases)
    func aTaskStartsAtItsStatedPriority(priority: WorkPriority) async throws {
        let work = BackgroundWork(label: "test.task.priority")
        let started = Signal()
        let seen = OSAllocatedUnfairLock<TaskPriority?>(initialState: nil)
        // Detached: the caller's priority does not pass to it. The test meets it through a signal, not
        // `value`, so no waiter escalates it before it reads its priority.
        let task = work.task(priority) {
            seen.withLock { $0 = Task.currentPriority }
            started.send()
        }
        await started.wait()
        #expect(seen.withLock { $0 }.map { WorkPriority($0) } == priority)
        try await task.value
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
