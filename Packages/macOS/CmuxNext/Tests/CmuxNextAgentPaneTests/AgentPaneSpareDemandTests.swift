@testable import CmuxNextAgentPane
import Testing

/// The pool's size rule as a value (AgentPaneSpareDemand, decision 2026-11-16): as many pages as the opens of the
/// last second asked for, 3 at most, until 60 s passed with no open; then the pool's own count again.
@Suite struct AgentPaneSpareDemandTests {
    @Test func oneOpenNowAndThenKeepsOnePage() {
        var demand = AgentPaneSpareDemand()
        #expect(demand.size == 1)
        #expect(demand.asked(at: .seconds(5)) == 1)
        // Opens one second apart are no burst.
        #expect(demand.asked(at: .seconds(6)) == 1)
        #expect(demand.asked(at: .seconds(40)) == 1)
        #expect(!demand.isGrown)
    }

    @Test func aBurstRaisesTheSizeToItsOpensAndThreeAtMost() {
        var demand = AgentPaneSpareDemand()
        #expect(demand.asked(at: .milliseconds(0)) == 1)
        #expect(demand.asked(at: .milliseconds(400)) == 2)
        #expect(demand.asked(at: .milliseconds(999)) == 3)
        #expect(demand.asked(at: .milliseconds(1_000)) == 3)
        #expect(demand.asked(at: .milliseconds(1_001)) == 3)
        #expect(AgentPaneSpareDemand.most == 3 && demand.isGrown)
    }

    /// The size a burst reached stays while opens go on, also slow ones: only 60 s with no open end it.
    @Test func theSizeStaysUntilSixtySecondsPassedWithNoOpen() {
        var demand = AgentPaneSpareDemand()
        demand.asked(at: .seconds(10))
        #expect(demand.asked(at: .milliseconds(10_500)) == 2)
        #expect(demand.asked(at: .seconds(40)) == 2)
        #expect(demand.released(at: .seconds(70)) == nil, "the pages went 30 s after an open")
        #expect(demand.released(at: .milliseconds(99_999)) == nil)
        #expect(demand.size == 2)
        #expect(demand.released(at: .seconds(100)) == 1)
        #expect(demand.size == 1 && !demand.isGrown)
        // After the release a single open is a single open again.
        #expect(demand.asked(at: .milliseconds(100_200)) == 1)
    }

    @Test func thePoolsOwnCountIsTheFloor() {
        var demand = AgentPaneSpareDemand(floor: 2)
        #expect(demand.asked(at: .zero) == 2)
        #expect(!demand.isGrown, "one open of a pool of 2 is no burst")
        demand.asked(at: .milliseconds(100))
        #expect(demand.asked(at: .milliseconds(200)) == 3)
        #expect(demand.released(at: .seconds(61)) == 2)
        demand.floor = 0
        #expect(demand.size == 1, "the pool keeps one page at least")
    }

    @Test func forgetEndsTheBurstAtOnce() {
        var demand = AgentPaneSpareDemand()
        for _ in 0..<3 { demand.asked(at: .seconds(1)) }
        #expect(demand.size == 3)
        demand.forget()
        #expect(demand.size == 1 && !demand.isGrown)
        #expect(demand.asked(at: .milliseconds(1_100)) == 1, "an open before the pressure counted after it")
    }

    /// The pool's queue at a smaller size: the pages over it leave, the next one to hand out stays.
    @Test func trimKeepsTheNextPageToHandOut() {
        var slot = AgentPaneSpareSlot<Int>(capacity: 3)
        for page in 1...3 { slot.parked(page) }
        #expect(slot.trim(to: 1) == [2, 3])
        #expect(slot.all == [1] && slot.capacity == 1 && !slot.shouldWarm)
        #expect(slot.trim(to: 3).isEmpty)
        #expect(slot.all == [1] && slot.shouldWarm)
        #expect(slot.trim(to: 0).isEmpty && slot.capacity == 1, "the queue keeps room for one page")
    }
}
