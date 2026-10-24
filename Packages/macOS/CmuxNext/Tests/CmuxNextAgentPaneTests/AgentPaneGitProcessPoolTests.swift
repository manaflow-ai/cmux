import os
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A git run is awaited with no thread waiting (AsyncProcess): many slow runs at once never hold the
/// cooperative pool (one thread per core), so other async work keeps running while they wait.
/// Before: each run waited on a DispatchSemaphore inside Task.detached, holding one pool thread per run.
@Suite(.timeLimit(.minutes(1))) struct AgentPaneGitProcessPoolTests {
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
            for index in 0..<(count * 4) { group.addTask { index } }
            return await group.reduce(0) { total, _ in total + 1 }
        }
        #expect(done == count * 4)
        #expect(ended.withLock { $0 } == 0, "the burst finished while every git run was still waiting")
        runs.forEach { $0.cancel() }
        for run in runs { await run.value }
    }
}
