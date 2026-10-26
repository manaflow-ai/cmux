import CmuxNextInputCore
import Testing

/// The held prewarms (p04-input-042/043): FIFO of 2, oldest evicted first, as Chrome holds at most two
/// non-eager prerenders (prerender_host_registry.cc, `kMaxNumOfRunningNonEagerPrerendersExceeded`).
struct IntentPrewarmTests {
    @Test func theQueueHoldsTwoAndEvictsTheOldest() {
        var queue = IntentPrewarmQueue<String>()
        #expect(queue.limit == 2)
        #expect(queue.admit("a", by: .hoverDwell) == nil)
        #expect(queue.admit("b", by: .hoverDwell) == nil)
        #expect(queue.admit("c", by: .hoverDwell) == "a")
        #expect(queue.held == ["b", "c"])
        #expect(queue.admit("d", by: .hoverDwell) == "b")
        #expect(queue.held == ["c", "d"])
    }

    @Test func admittingAHeldTargetChangesNothing() {
        var queue = IntentPrewarmQueue<String>()
        _ = queue.admit("a", by: .hoverDwell)
        _ = queue.admit("b", by: .hoverDwell)
        #expect(queue.admit("a", by: .hoverDwell) == nil, "a held target is not started twice, so nothing is evicted")
        #expect(queue.held == ["a", "b"], "and it keeps its age")
    }

    @Test func removeLetsOneGoAndRemoveAllReturnsTheRestOldestFirst() {
        var queue = IntentPrewarmQueue<String>()
        _ = queue.admit("a", by: .hoverDwell)
        _ = queue.admit("b", by: .hoverDwell)
        let removed = queue.remove("a")
        #expect(removed == .hoverDwell)
        let removedAgain = queue.remove("a")
        #expect(removedAgain == nil)
        #expect(!queue.contains("a"))
        _ = queue.admit("c", by: .hoverDwell)
        #expect(queue.removeAll() == ["b", "c"])
        #expect(queue.held.isEmpty)
    }

    /// p04-input-042: hover and press prewarms share the one FIFO; each held one keeps the trigger that
    /// started it until it leaves, so a use is counted by trigger.
    @Test func pressAndHoverShareTheFIFOAndEachKeepsItsTrigger() {
        var queue = IntentPrewarmQueue<String>()
        _ = queue.admit("a", by: .hoverDwell)
        _ = queue.admit("b", by: .pointerDown)
        #expect(queue.admit("b", by: .hoverDwell) == nil)
        #expect(queue.triggers == ["a": .hoverDwell, "b": .pointerDown], "a held target keeps its first trigger")
        #expect(queue.admit("c", by: .pointerDown) == "a")
        #expect(queue.triggers == ["b": .pointerDown, "c": .pointerDown], "the evicted one's trigger goes with it")
        let removed = queue.remove("b")
        #expect(removed == .pointerDown)
        #expect(queue.removeAll() == ["c"])
        #expect(queue.triggers.isEmpty)
    }

    @Test func aLimitBelowOneHoldsOne() {
        var queue = IntentPrewarmQueue<Int>(limit: 0)
        #expect(queue.limit == 1)
        _ = queue.admit(1, by: .hoverDwell)
        #expect(queue.admit(2, by: .pointerDown) == 1)
        #expect(queue.held == [2])
    }

    @Test func onlyLowPowerModeOnBatterySavesBattery() {
        #expect(IntentPrewarmPower(lowPowerMode: true, onBattery: true).savesBattery)
        #expect(!IntentPrewarmPower(lowPowerMode: true, onBattery: false).savesBattery)
        #expect(!IntentPrewarmPower(lowPowerMode: false, onBattery: true).savesBattery)
    }
}
