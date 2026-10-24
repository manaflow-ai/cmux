import CmuxNextWakeups
import Foundation
import os
import Testing

/// AsyncProcess: a child's run is awaited without parking any thread (the cooperative pool stays free),
/// with its whole output, its exit, and SIGTERM on timeout and cancel.
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
        var request = Self.tool("/bin/sleep", "30")
        request.timeout = .milliseconds(100)
        await #expect(throws: ProcessFailure.timedOut) { try await processes.run(request) }
    }

    @Test func aCancelledCallerStopsTheChild() async {
        let run = Task { try await processes.run(Self.tool("/bin/sleep", "30")) }
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
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

    @MainActor @Test func aMainActorCallerNeverSpawnsOnTheMainThread() async throws {
        // A fork and exec can take hundreds of ms under memory pressure (807 ms in STRESS, PL-main): the
        // main actor awaits the run, and the spawn itself happens on another thread.
        let spawnedOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let processes = AsyncProcess { process in
            spawnedOnMain.withLock { $0 = Thread.isMainThread }
            try process.run()
        }
        let outcome = try await processes.run(Self.tool("/usr/bin/true"))
        #expect(outcome.succeeded)
        #expect(spawnedOnMain.withLock { $0 } == false)
    }
}
