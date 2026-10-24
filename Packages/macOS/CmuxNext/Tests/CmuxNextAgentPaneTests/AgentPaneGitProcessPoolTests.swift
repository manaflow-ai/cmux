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
        // More waiting runs than the pool has threads; each child sleeps far longer than the burst needs.
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        let ended = OSAllocatedUnfairLock(initialState: 0)
        let runs = (0..<count).map { _ in
            Task(priority: .high) {
                _ = await AgentPaneGitProcess.output(["20"], executable: "/bin/sleep", timeout: .seconds(40))
                ended.withLock { $0 += 1 }
            }
        }
        // Let the runs start first: each starts at a higher priority than this burst.
        for _ in 0..<count { await Task.yield() }
        let done = await withTaskGroup(of: Int.self) { group in
            for index in 0..<(count * 4) { group.addTask(priority: .high) { index } }
            var finished = 0
            for await _ in group { finished += 1 }
            return finished
        }
        #expect(done == count * 4)
        #expect(ended.withLock { $0 } == 0, "the burst finished while every git run was still waiting")
        runs.forEach { $0.cancel() }
        for run in runs { await run.value }
    }
}
