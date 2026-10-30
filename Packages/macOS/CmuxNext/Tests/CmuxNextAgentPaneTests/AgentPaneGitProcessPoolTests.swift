import os
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A git run is awaited with no thread waiting (AsyncProcess): many slow runs at once never hold the
/// cooperative pool (one thread per core), so other async work keeps running while they wait.
/// Before: each run waited on a DispatchSemaphore inside Task.detached(priority: .userInitiated), holding
/// one thread of that priority's pool per run. The pool is per QoS, so the burst runs at the same priority.
@Suite(.timeLimit(.minutes(1))) nonisolated struct AgentPaneGitProcessPoolTests {
    @Test func slowGitRunsLeaveTheCooperativePoolFree() async {
        // More waiting runs than the pool has threads. Each child outlives its deadline, so every run ends
        // at its deadline (a git run ignores its caller's cancel, `.finish`). If a run held a pool thread,
        // the burst below could start only when a run ended and freed one; with no thread waiting, it
        // finishes while every run still waits.
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        let ended = OSAllocatedUnfairLock(initialState: 0)
        let runs = (0..<count).map { _ in
            Task(priority: .high) {
                _ = await AgentPaneGitProcess.output(["120"], executable: "/bin/sleep", timeout: .seconds(3))
                ended.withLock { $0 += 1 }
            }
        }
        // Let the runs start first: each starts at the burst's priority.
        for _ in 0..<count { await Task.yield() }
        let done = await withTaskGroup(of: Int.self) { group in
            for index in 0..<(count * 4) { group.addTask(priority: .high) { index } }
            var finished = 0
            for await _ in group { finished += 1 }
            return finished
        }
        #expect(done == count * 4)
        #expect(ended.withLock { $0 } == 0, "the burst finished while every run still waited for its child")
        for run in runs { await run.value }
    }

    @Test func aCancelledCallerDoesNotStopAGitRun() async throws {
        // A page reload cancels its request; the git write it started must still run to its end. The caller
        // is cancelled before the run, so no step can be skipped at the call either.
        let folder = FileManager.default.temporaryDirectory.appending(path: "git-finish-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let steps = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let first = await AgentPaneGitProcess.output(["-c", "printf one > first"], executable: "/bin/sh",
                                                         directory: folder, timeout: .seconds(20))
            let second = await AgentPaneGitProcess.output(["-c", "printf two > second"], executable: "/bin/sh",
                                                          directory: folder, timeout: .seconds(20))
            return (first.status, second.status)
        }
        let (first, second) = await steps.value
        #expect(first == 0 && second == 0)
        #expect((try? String(contentsOfFile: folder + "/first", encoding: .utf8)) == "one")
        #expect((try? String(contentsOfFile: folder + "/second", encoding: .utf8)) == "two")
    }
}
