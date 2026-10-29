import CmuxNextInputCore
import Testing

/// The held prewarms: FIFO of 2, oldest evicted first, as Chrome holds at most two
/// non-eager prerenders (prerender_host_registry.cc, `kMaxNumOfRunningNonEagerPrerendersExceeded`).
struct IntentPrewarmTests {
    @Test func theQueueHoldsTwoAndEvictsTheOldest() {
        var queue = IntentPrewarmQueue<String>()
        #expect(queue.limit == 2)
        #expect(queue.admit("a", trigger: .hoverDwell) == nil)
        #expect(queue.admit("b", trigger: .hoverDwell) == nil)
        #expect(queue.admit("c", trigger: .hoverDwell) == "a")
        #expect(queue.held == ["b", "c"])
        #expect(queue.admit("d", trigger: .hoverDwell) == "b")
        #expect(queue.held == ["c", "d"])
    }

    @Test func admittingAHeldTargetChangesNothing() {
        var queue = IntentPrewarmQueue<String>()
        _ = queue.admit("a", trigger: .hoverDwell)
        _ = queue.admit("b", trigger: .hoverDwell)
        #expect(queue.admit("a", trigger: .hoverDwell) == nil, "a held target is not started twice, so nothing is evicted")
        #expect(queue.held == ["a", "b"], "and it keeps its age")
    }

    @Test func removeLetsOneGoAndRemoveAllReturnsTheRestOldestFirst() {
        var queue = IntentPrewarmQueue<String>()
        _ = queue.admit("a", trigger: .hoverDwell)
        _ = queue.admit("b", trigger: .hoverDwell)
        let removed = queue.remove("a")
        #expect(removed == .hoverDwell)
        let removedAgain = queue.remove("a")
        #expect(removedAgain == nil)
        #expect(!queue.contains("a"))
        _ = queue.admit("c", trigger: .hoverDwell)
        #expect(queue.removeAll() == ["b", "c"])
        #expect(queue.held.isEmpty)
    }

    @Test func eachHeldPrewarmKeepsItsTriggerUntilItLeaves() {
        var queue = IntentPrewarmQueue<String>()
        _ = queue.admit("x", trigger: .keyStep)
        _ = queue.admit("h1", trigger: .hoverDwell)
        #expect(queue.admit("x", trigger: .hoverDwell) == nil)
        #expect(queue.trigger(of: "x") == .keyStep, "a held target keeps the trigger that started it")
        #expect(queue.admit("h2", trigger: .hoverDwell) == "x")
        #expect(queue.trigger(of: "x") == nil, "an evicted target leaves with its trigger")
        _ = queue.admit("x", trigger: .hoverDwell)
        #expect(queue.trigger(of: "x") == .hoverDwell, "a target admitted again carries its new trigger")
        #expect(queue.removeAll(startedBy: .keyStep).isEmpty)
        #expect(queue.held == ["h2", "x"])
    }

    @Test func removeAllStartedByOneTriggerKeepsTheOthersInOrder() {
        var queue = IntentPrewarmQueue<String>(limit: 4)
        _ = queue.admit("a", trigger: .keyStep)
        _ = queue.admit("b", trigger: .pointerDown)
        _ = queue.admit("c", trigger: .keyStep)
        _ = queue.admit("d", trigger: .hoverDwell)
        #expect(queue.removeAll(startedBy: .keyStep) == ["a", "c"])
        #expect(queue.held == ["b", "d"])
        #expect(!queue.contains("a"))
        queue.remove("b")
        #expect(queue.trigger(of: "b") == nil)
    }

    /// Hover and press prewarms share the one FIFO; each held one keeps the trigger that
    /// started it until it leaves, so a use is counted by trigger.
    @Test func pressAndHoverShareTheFIFOAndEachKeepsItsTrigger() {
        var queue = IntentPrewarmQueue<String>()
        _ = queue.admit("a", trigger: .hoverDwell)
        _ = queue.admit("b", trigger: .pointerDown)
        #expect(queue.admit("b", trigger: .hoverDwell) == nil)
        #expect(queue.trigger(of: "a") == .hoverDwell)
        #expect(queue.trigger(of: "b") == .pointerDown, "a held target keeps its first trigger")
        #expect(queue.admit("c", trigger: .pointerDown) == "a")
        #expect(queue.trigger(of: "a") == nil, "the evicted one's trigger goes with it")
        #expect(queue.trigger(of: "c") == .pointerDown)
        let removed = queue.remove("b")
        #expect(removed == .pointerDown)
        #expect(queue.removeAll() == ["c"])
        #expect(queue.trigger(of: "c") == nil)
    }

    @Test func aLimitBelowOneHoldsOne() {
        var queue = IntentPrewarmQueue<Int>(limit: 0)
        #expect(queue.limit == 1)
        _ = queue.admit(1, trigger: .hoverDwell)
        #expect(queue.admit(2, trigger: .pointerDown) == 1)
        #expect(queue.held == [2])
    }

    @Test func onlyLowPowerModeOnBatterySavesBattery() {
        #expect(IntentPrewarmPower(lowPowerMode: true, onBattery: true).savesBattery)
        #expect(!IntentPrewarmPower(lowPowerMode: true, onBattery: false).savesBattery)
        #expect(!IntentPrewarmPower(lowPowerMode: false, onBattery: true).savesBattery)
    }
}
