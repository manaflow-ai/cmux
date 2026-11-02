import CmuxNextWakeups
import Darwin
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

    @Test func aProcessGroupStopsDescendantsThatOutliveTheirGitLeader() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "async-process-group-\(UUID().uuidString)").path
        defer { unlink(marker) }
        // The leader ignores TERM and waits for a descendant. The descendant records TERM and exits;
        // a direct-pid stop leaves it running, while the process-group stop reaches it atomically.
        // `.finish`: the run resolves at the leader's exit, which waits for the descendant's trap to write the
        // marker; a `.stop` run resolves at the timeout itself, before the descendant has run its trap.
        let script = "trap '' TERM; /bin/sh -c 'trap \"echo term > \\(marker); exit 0\" TERM; while :; do sleep 1; done' & wait"
        let request = ProcessRequest(URL(fileURLWithPath: "/bin/sh"), ["-c", script], timeout: .seconds(1),
                                     onCancel: .finish, killGrace: .seconds(2), terminationScope: .processGroup)
        await #expect(throws: ProcessFailure.timedOut) { try await processes.run(request) }
        #expect(FileManager.default.fileExists(atPath: marker))
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
        // AsyncProcess.run is @concurrent: with NonisolatedNonsendingByDefault a plain async function would
        // run its setup and posix_spawn on the caller's actor, here the main thread.
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

    @Test(arguments: [(WorkPriority.idle, QualityOfService.background), (.bestEffort, .utility),
                      (.userVisible, .default), (.userBlocking, .userInitiated)])
    func eachWaiterPriorityHasOneChildQoSAndNeverUserInteractive(priority: WorkPriority, qos: QualityOfService) {
        // A child's own QoS is not observable from a test without a helper binary (the system python3 is a
        // shim that spawns the real one at the default QoS), so the mapping AsyncProcess applies is checked.
        #expect(priority.processQoS == qos)
        #expect(priority.processQoS != .userInteractive)
    }
}
