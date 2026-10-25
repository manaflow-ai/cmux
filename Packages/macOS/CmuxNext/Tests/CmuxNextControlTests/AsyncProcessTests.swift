import CmuxNextWakeups
import Darwin
import Dispatch
import Foundation
import os
import Testing

/// AsyncProcess: a child's run is awaited without parking any thread (the cooperative pool stays free),
/// with its whole output, its exit, SIGTERM on timeout and cancel (SIGKILL after the grace), never a spawn
/// on the main thread, and `.finish` requests that outlive their caller's cancel.
@Suite(.timeLimit(.minutes(1))) struct AsyncProcessTests {
    let processes = AsyncProcess()

    static func tool(_ path: String, _ arguments: String...) -> ProcessRequest {
        ProcessRequest(URL(fileURLWithPath: path), arguments)
    }

    @Test func itReturnsTheExitStatusAndTheOutput() async throws {
        let outcome = try await processes.run(Self.tool("/bin/sh", "-c", "printf hello; exit 3"))
        #expect(outcome.text == "hello")
        #expect(outcome.status == 3 && outcome.exited && !outcome.succeeded)
    }

    @Test func outputLargerThanThePipeBufferIsReadWhole() async throws {
        let outcome = try await processes.run(Self.tool("/usr/bin/head", "-c", "1000000", "/dev/zero"))
        #expect(outcome.succeeded)
        #expect(outcome.output.count == 1_000_000)
    }

    @Test func standardErrorMergesOrStaysSeparate() async throws {
        var request = Self.tool("/bin/sh", "-c", "printf out; printf err >&2")
        request.errorOutput = .merge
        let merged = try await processes.run(request)
        #expect(merged.text.contains("out") && merged.text.contains("err"))
        request.errorOutput = .separate
        let separate = try await processes.run(request)
        #expect(separate.text == "out")
        #expect(String(decoding: separate.errorOutput, as: UTF8.self) == "err")
    }

    @Test func inputReachesTheChildAndCloses() async throws {
        var request = Self.tool("/bin/cat")
        request.input = Data(repeating: UInt8(ascii: "x"), count: 300_000)
        let outcome = try await processes.run(request)
        #expect(outcome.succeeded)
        #expect(outcome.output == request.input)
    }

    @Test func aGrandchildHoldingThePipeDoesNotHoldTheResult() async throws {
        // sh exits at once; its background sleep keeps the output pipe open for two seconds.
        let started = ContinuousClock.now
        let outcome = try await processes.run(Self.tool("/bin/sh", "-c", "sleep 2 & printf hi"))
        #expect(outcome.text == "hi")
        #expect(ContinuousClock.now - started < .seconds(2), "the run ended at sh's exit, not at the pipe's EOF")
    }

    @Test func aMissingProgramIsALaunchFailure() async {
        await #expect(throws: ProcessFailure.self) {
            try await processes.run(Self.tool("/nonexistent/tool"))
        }
    }

    @Test func pastItsTimeoutTheChildIsStopped() async {
        // The child would sleep past the suite's one-minute limit: the test ends only when the stop killed it.
        let child = ChildExit()
        let request = ProcessRequest(URL(fileURLWithPath: "/bin/sleep"), ["600"], timeout: .milliseconds(100),
                                     onLaunch: { child.watch($0) })
        await #expect(throws: ProcessFailure.timedOut) { try await processes.run(request) }
        await child.exit()
    }

    @Test func aCancelledCallerStopsItsRunningChild() async {
        let child = ChildExit()
        let (launched, launch) = AsyncStream.makeStream(of: Int32.self)
        let request = ProcessRequest(URL(fileURLWithPath: "/bin/sleep"), ["600"], onLaunch: { pid in
            child.watch(pid)
            launch.yield(pid)
        })
        let run = Task { try await processes.run(request) }
        // Cancel only once the child runs, so the cancel handler (not the check at the call) stops it.
        var iterator = launched.makeAsyncIterator()
        _ = await iterator.next()
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        await child.exit()
    }

    @Test func aStopThatComesDuringOnLaunchSignalsTheChildOnlyAfterItReturns() async throws {
        // onLaunch holds until the caller's cancel (a stop) has come. The child must not get the stop signal
        // before onLaunch returns: a watcher it starts must find the child alive.
        let gate = DispatchSemaphore(value: 0)
        let returned = OSAllocatedUnfairLock(initialState: false)
        let exitedFirst = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let (launched, launch) = AsyncStream.makeStream(of: Int32.self)
        let (exited, exitReport) = AsyncStream.makeStream(of: Void.self)
        let watchers = OSAllocatedUnfairLock<[any DispatchSourceProcess]>(initialState: [])
        let request = ProcessRequest(URL(fileURLWithPath: "/bin/sleep"), ["600"], onLaunch: { pid in
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                exitedFirst.withLock { $0 = !returned.withLock { $0 } }
                source.cancel()
                exitReport.yield()
                gate.signal()  // a child killed while onLaunch waits frees it
            }
            watchers.withLock { $0.append(source) }
            source.activate()
            launch.yield(pid)
            gate.wait()
            returned.withLock { $0 = true }
        })
        let processes = processes
        let run = Task { try await processes.run(request) }
        var iterator = launched.makeAsyncIterator()
        _ = await iterator.next()
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        gate.signal()
        var exits = exited.makeAsyncIterator()
        _ = await exits.next()
        #expect(exitedFirst.withLock { $0 } == false, "the child got the stop signal while onLaunch ran")
    }

    /// A real clock that reports each finished sleep (the kill grace's end) just before its timer's handler runs.
    struct WakeReportingClock: Clock {
        typealias Duration = Swift.Duration
        typealias Instant = ContinuousClock.Instant
        let onWake: @Sendable () -> Void
        var now: Instant { ContinuousClock.now }
        var minimumResolution: Swift.Duration { ContinuousClock().minimumResolution }
        func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
            try await ContinuousClock().sleep(until: deadline, tolerance: tolerance)
            onWake()
        }
    }

    @Test func aKillGraceThatEndsDuringOnLaunchStillKillsTheChild() async {
        // The stop signal is SIGURG, which sleep ignores by default (no race with a shell's trap); the caller cancels
        // while onLaunch runs, and the kill grace ends before onLaunch returns: the SIGKILL must reach the child once
        // its pid is published (it used to go to no pid), else the child sleeps past the suite's limit.
        let gate = DispatchSemaphore(value: 0)
        let child = ChildExit()
        let (launched, launch) = AsyncStream.makeStream(of: Void.self)
        let request = ProcessRequest(URL(fileURLWithPath: "/bin/sleep"), ["600"], stopSignal: SIGURG,
                                     killGrace: .milliseconds(1), onLaunch: { pid in
            child.watch(pid)
            launch.yield()
            gate.wait()
        })
        let processes = AsyncProcess(clock: WakeReportingClock { gate.signal() })
        let run = Task { try await processes.run(request) }
        var iterator = launched.makeAsyncIterator()
        _ = await iterator.next()
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        await child.exit()
    }

    @Test func aStoppedChildThatIgnoresTheStopSignalIsKilledAfterItsGrace() async {
        // `exec`: sleep itself ignores SIGTERM (an ignored signal stays ignored across exec), so only SIGKILL
        // ends it before the suite's limit, and no orphan outlives the test.
        let child = ChildExit()
        let request = ProcessRequest(URL(fileURLWithPath: "/bin/sh"), ["-c", "trap '' TERM; exec /bin/sleep 600"],
                                     timeout: .milliseconds(100), killGrace: .milliseconds(200),
                                     onLaunch: { child.watch($0) })
        await #expect(throws: ProcessFailure.timedOut) { try await processes.run(request) }
        await child.exit()
    }

    @Test func aFinishRequestRunsToItsEndThoughItsCallerIsCancelled() async throws {
        // The child waits on a fifo that only the test writes, after its cancel: it is surely running then.
        let fifo = FileManager.default.temporaryDirectory.appending(path: "async-process-\(UUID().uuidString)").path
        try #require(mkfifo(fifo, 0o600) == 0)
        defer { unlink(fifo) }
        let (launched, launch) = AsyncStream.makeStream(of: Int32.self)
        let request = ProcessRequest(URL(fileURLWithPath: "/bin/sh"), ["-c", "read line < \"$0\"; printf %s \"$line\"", fifo],
                                     onCancel: .finish, onLaunch: { launch.yield($0) })
        let run = Task { try await processes.run(request) }
        var iterator = launched.makeAsyncIterator()
        _ = await iterator.next()
        run.cancel()
        // Blocks until sh opens the fifo to read it; a stopped sh never would, and the suite's limit fails the test.
        let writer = open(fifo, O_WRONLY)
        try #require(writer >= 0)
        _ = "done\n".withCString { write(writer, $0, 5) }
        close(writer)
        let outcome = try await run.value
        #expect(outcome.succeeded)
        #expect(outcome.text == "done")
    }

    @MainActor @Test func aMainActorCallerNeverSpawnsOnTheMainThread() async throws {
        // The spawn runs on the run's own serial queue (ProcessRun), and AsyncProcess.run is @concurrent: with
        // NonisolatedNonsendingByDefault a plain async function would run its setup on the caller's actor, here
        // the main thread.
        let onMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let request = ProcessRequest(URL(fileURLWithPath: "/usr/bin/true"), onLaunch: { _ in
            onMain.withLock { $0 = pthread_main_np() != 0 }
        })
        let outcome = try await processes.run(request)
        #expect(outcome.succeeded)
        #expect(onMain.withLock { $0 } == false)
    }

    @Test func aCallerCancelledAsItStartsEndsAtOnce() async {
        // Cancel races the run's start: every run ends (none hangs), whichever side wins.
        for _ in 0..<200 {
            let run = Task { try await processes.run(Self.tool("/bin/sleep", "30")) }
            run.cancel()
            _ = try? await run.value
        }
    }

    @Test func manyRunningChildrenLeaveTheCooperativePoolFree() async throws {
        // More waiting children than the pool has threads: with waitUntilExit inside tasks they would hold
        // every pool thread, and the task group below would never run.
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        let runs = (0..<count).map { _ in Task(priority: .high) { try await processes.run(Self.tool("/bin/sleep", "30")) } }
        let done = await withTaskGroup(of: Int.self) { group in
            // At the runs' priority: the pool is per QoS, so only same-priority work would starve.
            for index in 0..<(count * 4) { group.addTask(priority: .high) { index } }
            var finished = 0
            for await _ in group { finished += 1 }
            return finished
        }
        #expect(done == count * 4)
        runs.forEach { $0.cancel() }
        for run in runs { _ = try? await run.value }
    }

    @Test func theSpawnRunsOnTheRunsOwnQueueNotTheCooperativePool() async throws {
        // A spawn can block for hundreds of ms: on the cooperative pool it would hold a pool thread.
        let queue = OSAllocatedUnfairLock<String?>(initialState: nil)
        let request = ProcessRequest(URL(fileURLWithPath: "/usr/bin/true"), onLaunch: { _ in
            queue.withLock { $0 = String(cString: __dispatch_queue_get_label(nil)) }
        })
        #expect(try await processes.run(request).succeeded)
        #expect(queue.withLock { $0 } == "com.cmuxterm.next.process.true")
    }

    /// The base scheduling priority of `pid`'s first thread, which its QoS sets (background 4, utility 20,
    /// default 31, userInitiated 37); nil when the kernel does not answer.
    static func basePriority(of pid: Int32) -> Int32? {
        var threads = [UInt64](repeating: 0, count: 16)
        let listed = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &threads, Int32(threads.count * MemoryLayout<UInt64>.size))
        guard listed >= Int32(MemoryLayout<UInt64>.size) else { return nil }
        var info = proc_threadinfo()
        let size = Int32(MemoryLayout<proc_threadinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTHREADINFO, threads[0], &info, size) == size else { return nil }
        return info.pth_priority
    }

    /// The measured priority of a child that `waiter` awaits with the request's `priority`.
    func childPriority(waiter: TaskPriority, request priority: WorkPriority?) async throws -> Int32 {
        let (seen, report) = AsyncStream.makeStream(of: Int32?.self)
        let request = ProcessRequest(URL(fileURLWithPath: "/bin/sleep"), ["30"], priority: priority,
                                     onLaunch: { report.yield(Self.basePriority(of: $0)) })
        let processes = processes
        let run = Task(priority: waiter) { try await processes.run(request) }
        var iterator = seen.makeAsyncIterator()
        let measured = await iterator.next() ?? nil
        run.cancel()
        _ = try? await run.value
        return try #require(measured, "no thread info for the child")
    }

    @Test func aChildRunsAtItsWaitersPriority() async throws {
        // Measured on the child itself (its main thread's base priority), not read off the mapping table.
        let background = try await childPriority(waiter: .background, request: nil)
        let high = try await childPriority(waiter: .high, request: nil)
        #expect(background < high, "background waiter's child \(background), high waiter's \(high)")
        #expect(high < 47, "a child never runs at userInteractive (47): \(high)")
    }

    @Test func aRequestsOwnPriorityHoldsUnderAHigherWaiter() async throws {
        // A poll states bestEffort; awaited from a high task (a main-actor poll loop) its child stays below the
        // child of the same waiter that takes the caller's priority.
        let poll = try await childPriority(waiter: .high, request: .bestEffort)
        let caller = try await childPriority(waiter: .high, request: nil)
        let idle = try await childPriority(waiter: .high, request: .idle)
        #expect(idle < poll && poll < caller, "idle \(idle), bestEffort \(poll), caller's \(caller)")
    }

    @Test(arguments: WorkPriority.allCases)
    func noPriorityMapsAChildToUserInteractive(priority: WorkPriority) {
        #expect(priority.processQoS != .userInteractive)
    }
}
