import CmuxNextWakeups
import Foundation
import Testing

/// The input-response state and the typing-burst rate of ``MainFrameBudget`` (p06-scheduler-002):
/// a discrete input that expects a frame holds automation and background until the next
/// link tick has rendered (at most 100 ms), and while a person types they run one task per 100 ms.
extension MainFrameBudgetTests {
    @Test func aKeyThatExpectsNoFrameOpensNoInputResponse() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.noteDiscreteInput(expectsFrame: false)
        #expect(!budget.isInputResponseOpen)
        #expect(budget.mayRun(.automation))
        #expect(budget.mayRun(.background))
        #expect(budget.stats.yieldedToInputResponse == [0, 0, 0])
    }

    @Test func automationWaitsForTheNextTicksRenderNotTheKeysOwnCommit() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.noteDiscreteInput(expectsFrame: true)
        #expect(!budget.mayRun(.automation))
        #expect(!budget.mayRun(.background))
        // The key's own turn commits (its CommitBoundary) before any tick of the link.
        budget.noteTickRenderEnded()
        #expect(budget.isInputResponseOpen, "the key's own commit does not close it")
        #expect(!budget.mayRun(.automation))
        clock.advance(nanos: ResponseClock.frame)
        budget.beginFrame(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(!budget.mayRun(.automation), "the tick after the key has not rendered yet")
        budget.noteTickRenderEnded()
        #expect(!budget.isInputResponseOpen)
        #expect(budget.mayRun(.automation))
        #expect(budget.mayRun(.background))
        #expect(budget.stats.yieldedToInputResponse == [0, 2, 1], "counted once per class and frame")
        #expect(budget.stats.maxInputResponseNanos == ResponseClock.frame)
        #expect(budget.stats.inputResponseCapHits == 0)
    }

    @Test func aUserBlockingCommitClosesTheInputResponse() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.noteDiscreteInput(expectsFrame: true)
        clock.advance(nanos: 3_000_000)
        budget.noteUserBlockingCommit()
        #expect(!budget.isInputResponseOpen)
        #expect(budget.mayRun(.automation))
        #expect(budget.stats.maxInputResponseNanos == 3_000_000)
    }

    @Test func anInputResponseWithNoRenderClosesAt100Milliseconds() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.noteDiscreteInput(expectsFrame: true)
        clock.advance(nanos: 50_000_000)
        #expect(budget.isInputResponseOpen)
        #expect(!budget.mayRun(.automation))
        clock.advance(nanos: 50_000_000)
        #expect(!budget.isInputResponseOpen)
        #expect(budget.mayRun(.automation))
        #expect(budget.stats.inputResponseCapHits == 1)
        #expect(budget.stats.maxInputResponseNanos == 100_000_000)
    }

    @Test func anInputResponseHoldsNeitherFrameWorkNorVisibleUpdates() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in ResponseFrameLink() }
        var order: [String] = []
        let automation = FrameClient(owner: "automation", budgeted: .automation, on: scheduler) { _, budget in
            budget.run(.automation, owner: budget.board.owner("automation")) { order.append("automation") }
            return true
        }
        let visible = FrameClient(owner: "visible", budgeted: .visible, on: scheduler) { _, budget in
            budget.run(.visible, owner: budget.board.owner("visible")) { order.append("visible") }
            return true
        }
        let spring = FrameClient(owner: "spring", on: scheduler.frames) { _ in order.append("frame"); return true }
        for client in [automation, visible, spring] { client.activate() }
        budget.noteDiscreteInput(expectsFrame: true)
        #expect(budget.mayRun(.input))
        #expect(budget.mayRun(.frame))
        clock.advance(nanos: ResponseClock.frame)
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(order == ["frame", "visible"], "the input response holds automation only")
        budget.noteTickRenderEnded()
        order.removeAll()
        clock.advance(nanos: ResponseClock.frame)
        scheduler.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(order == ["frame", "visible", "automation"])
        for client in [automation, visible, spring] { client.deactivate() }
    }

    /// Keys at 30 a second, each expecting a frame, against a queue of agent requests: the requests
    /// start at most ten a second and never more than 100 ms apart; once typing stops for 500 ms
    /// the frame's budget applies again.
    @Test func keysAt30PerSecondGiveAutomationOneTaskPer100Milliseconds() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in ResponseFrameLink() }
        let requests = FrameBatchQueue(owner: "Control.frames", budgeted: .automation, on: scheduler)
        var starts: [UInt64] = []
        for _ in 0..<400 { requests.enqueue { starts.append(clock.now); clock.advance(nanos: 100_000) } }
        let start = clock.now
        let keyInterval: UInt64 = 33_333_333
        var nextKey = start
        for frame in 0..<90 {
            let tickTime = start + UInt64(frame) * ResponseClock.frame
            while nextKey <= tickTime, nextKey < start + 1_500_000_000 {
                clock.set(max(nextKey, clock.now))
                budget.noteDiscreteInput(expectsFrame: true)
                budget.noteTickRenderEnded() // the key's own commit
                nextKey += keyInterval
            }
            clock.set(tickTime)
            scheduler.frameDidFire(timestamp: Double(frame + 1), refreshInterval: 1.0 / 60)
            budget.noteTickRenderEnded()
        }
        let typed = starts.filter { $0 < start + 1_500_000_000 }
        #expect(typed.count >= 14)
        for (earlier, later) in zip(typed, typed.dropFirst()) {
            #expect(later - earlier <= 100_001_000, "automation waited \(later - earlier) ns")
        }
        for index in typed.indices.dropLast(10) {
            #expect(typed[index + 10] - typed[index] >= 1_000_000_000, "more than ten requests in one second")
        }
        // Typing stopped 500 ms ago: the frame's budget applies, many requests a frame.
        let before = starts.count
        clock.set(start + 2_100_000_000)
        scheduler.frameDidFire(timestamp: 200, refreshInterval: 1.0 / 60)
        #expect(starts.count - before > 1)
    }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class ResponseClock {
    /// One 60 Hz frame.
    static let frame: UInt64 = 16_666_667
    private(set) var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(nanos: UInt64) { now += nanos }
    func set(_ value: UInt64) { now = value }
}

@MainActor
private final class ResponseFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
