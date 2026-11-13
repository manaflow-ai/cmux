@testable import CmuxNextAgentPane
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The close queue is the same scale seam used by ``AgentPageRetirer``. Before this queue the
/// retirer drained every page in one main-actor turn; the regression test keeps that turn bounded
/// to one page even when a workspace closes a large batch.
@Suite struct AgentPageRetirementQueueTests {
    @Test func aLaterWakeStateCannotOvertakeAnEarlierClose() {
        final class Page {
            let id: Int
            var wakeStateReady = false

            init(_ id: Int) { self.id = id }
        }

        var queue = AgentPageRetirementQueue<Page>()
        let first = Page(1), second = Page(2)
        queue.append(first)
        queue.append(second)
        second.wakeStateReady = true

        var closed: [Int] = []
        if queue.peek?.wakeStateReady == true { closed.append(queue.takeNext()!.id) }
        #expect(closed.isEmpty, "a later wake-state answer cannot overtake the first page")

        first.wakeStateReady = true
        while queue.peek?.wakeStateReady == true { closed.append(queue.takeNext()!.id) }
        #expect(closed == [1, 2])
    }

    @Test func retirementPreservesCloseOrder() {
        var queue = AgentPageRetirementQueue<Int>()
        for page in 0..<4 { queue.append(page) }

        var retired: [Int] = []
        while let page = queue.takeNext() { retired.append(page) }

        #expect(retired == [0, 1, 2, 3])
    }

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

    @Test func continuationDoesNotReplaceQuietTimer() async throws {
        actor Events {
            var values: [String] = []
            func append(_ value: String) { values.append(value) }
        }

        let clock = ManualClock()
        let timer = DemandTimer(owner: "AgentPageRetirementQueueTests", clock: clock)
        let events = Events()
        timer.schedule(after: .milliseconds(500)) { await events.append("quiet") }
        try await clock.waitForSleeper()

        timer.scheduleIfIdle(after: .milliseconds(1)) { await events.append("continuation") }
        #expect(clock.sleeperDeadlines.map(\.offset) == [.milliseconds(500)])

        clock.advance(by: .milliseconds(500))
        for _ in 0..<10 { await Task.yield() }
        #expect(await events.values == ["quiet"])
    }
}
