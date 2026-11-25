import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-24: "sometimes the highlights in terminal just float and dont move when i
/// scroll?" The timers behind a followed highlight, with the clock and the main queue run by hand.
@MainActor
@Suite struct TerminalHighlightTimingTests {
    @MainActor final class Queue {
        var clock = 0.0
        var due: [(delay: Double, work: @MainActor () -> Void)] = []
        var steps: [TerminalLostTextGrace.Step] = []
        var runs = 0
        var scheduler: TerminalMainScheduler { { [unowned self] delay, work in due.append((delay, work)) } }
        func runAll() {
            let now = due
            due = []
            for item in now { item.work() }
        }
    }

    @Test func lostTextHidesThenEndsWhenTheLookAgainFindsItStillGone() {
        let queue = Queue()
        let grace = TerminalLostTextGrace(now: { queue.clock }, schedule: queue.scheduler)
        func lookAgain() { queue.steps.append(grace.lost { queue.runs += 1 }) }

        #expect(grace.lost(lookAgain: lookAgain) == .hide)
        #expect(grace.isLost)
        #expect(queue.due.map(\.delay) == [TerminalLostTextGrace.grace])
        queue.clock = 0.2
        #expect(grace.lost(lookAgain: lookAgain) == .wait)
        #expect(queue.due.count == 1)
        // The timer fires a hair early by the clock: the look again still ends it.
        queue.clock = 0.499
        queue.runAll()
        #expect(queue.steps == [.end])
    }

    @Test func lostTextEndsByTheClockOnTheNextRedraw() {
        let queue = Queue()
        let grace = TerminalLostTextGrace(now: { queue.clock }, schedule: queue.scheduler)
        #expect(grace.lost {} == .hide)
        queue.clock = 0.5
        #expect(grace.lost {} == .end)
    }

    @Test func textBackWithinTheGraceCancelsTheEnd() {
        let queue = Queue()
        let grace = TerminalLostTextGrace(now: { queue.clock }, schedule: queue.scheduler)
        #expect(grace.lost { queue.runs += 1 } == .hide)
        queue.clock = 0.1
        #expect(grace.reset())
        #expect(!grace.isLost)
        queue.runAll()
        #expect(queue.runs == 0)
        // A new loss starts its own grace.
        queue.clock = 0.7
        #expect(grace.lost {} == .hide)
        queue.clock = 0.9
        #expect(grace.lost {} == .wait)
    }

    @Test func manyRedrawsInATurnSearchOnce() {
        let queue = Queue()
        let coalescer = TerminalTurnCoalescer(schedule: queue.scheduler)
        #expect(coalescer.request { queue.runs += 1 })
        #expect(!coalescer.request { queue.runs += 1 })
        #expect(!coalescer.request { queue.runs += 1 })
        #expect(queue.due.map(\.delay) == [0])
        queue.runAll()
        #expect(queue.runs == 1)
        // The next turn's redraw searches again.
        #expect(coalescer.request { queue.runs += 1 })
        queue.runAll()
        #expect(queue.runs == 2)
    }
}
