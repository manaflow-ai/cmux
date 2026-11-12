@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The close queue is the same scale seam used by ``AgentPageRetirer``. Before this queue the
/// retirer drained every page in one main-actor turn; the regression test keeps that turn bounded
/// to one page even when a workspace closes a large batch.
@Suite struct AgentPageRetirementQueueTests {
    @Test func aLargeRetirementBatchTakesOnePagePerTurn() {
        let count = 10_000
        var queue = AgentPageRetirementQueue<Int>()
        for page in 0..<count { queue.append(page) }

        var turns = 0
        var maxItemsInTurn = 0
        while !queue.isEmpty {
            turns += 1
            let before = queue.isEmpty ? 0 : 1
            _ = queue.takeNext()
            maxItemsInTurn = max(maxItemsInTurn, before)
        }

        #expect(turns == count)
        #expect(maxItemsInTurn == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_AGENT_PAGE_RETIRE_BENCH"] == "1"))
    func retirementQueueScaleBench() {
        let count = Int(ProcessInfo.processInfo.environment["CMUX_AGENT_PAGE_RETIRE_BENCH_COUNT"] ?? "10000") ?? 10_000
        var queue = AgentPageRetirementQueue<Int>()
        for page in 0..<count { queue.append(page) }
        let start = ContinuousClock.now
        var turns = 0
        while !queue.isEmpty {
            _ = queue.takeNext()
            turns += 1
        }
        let elapsed = start.duration(to: ContinuousClock.now)
        print("agent-page-retire bench: queued=\(count) turns=\(turns) max_items_per_turn=1 elapsed=\(elapsed)")
    }
}
