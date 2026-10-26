import CmuxNextInputCore
import Testing

/// The held prewarms (p04-input-042/043): FIFO of 2, oldest evicted first, as Chrome holds at most two
/// non-eager prerenders (prerender_host_registry.cc, `kMaxNumOfRunningNonEagerPrerendersExceeded`).
struct IntentPrewarmTests {
    @Test func theQueueHoldsTwoAndEvictsTheOldest() {
        var queue = IntentPrewarmQueue<String>()
        #expect(queue.limit == 2)
        #expect(queue.admit("a") == nil)
        #expect(queue.admit("b") == nil)
        #expect(queue.admit("c") == "a")
        #expect(queue.held == ["b", "c"])
        #expect(queue.admit("d") == "b")
        #expect(queue.held == ["c", "d"])
    }

    @Test func admittingAHeldTargetChangesNothing() {
        var queue = IntentPrewarmQueue<String>()
        _ = queue.admit("a")
        _ = queue.admit("b")
        #expect(queue.admit("a") == nil, "a held target is not started twice, so nothing is evicted")
        #expect(queue.held == ["a", "b"], "and it keeps its age")
    }

    @Test func removeLetsOneGoAndRemoveAllReturnsTheRestOldestFirst() {
        var queue = IntentPrewarmQueue<String>()
        _ = queue.admit("a")
        _ = queue.admit("b")
        #expect(queue.remove("a"))
        #expect(!queue.remove("a"))
        #expect(!queue.contains("a"))
        _ = queue.admit("c")
        #expect(queue.removeAll() == ["b", "c"])
        #expect(queue.held.isEmpty)
    }

    @Test func aLimitBelowOneHoldsOne() {
        var queue = IntentPrewarmQueue<Int>(limit: 0)
        #expect(queue.limit == 1)
        _ = queue.admit(1)
        #expect(queue.admit(2) == 1)
        #expect(queue.held == [2])
    }

    @Test func onlyLowPowerModeOnBatterySavesBattery() {
        #expect(IntentPrewarmPower(lowPowerMode: true, onBattery: true).savesBattery)
        #expect(!IntentPrewarmPower(lowPowerMode: true, onBattery: false).savesBattery)
        #expect(!IntentPrewarmPower(lowPowerMode: false, onBattery: true).savesBattery)
    }
}
