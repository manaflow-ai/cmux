import CmuxNextCompat
import CmuxNextInput
import CmuxNextInputCore
import CmuxNextWakeups
import Testing

/// Hover-dwell prewarm (p04-input-043): one MainDeadline, pending only while the pointer rests on a cold
/// target, restarted on another target and cancelled on nothing, a press or a commit; the prewarm starts
/// after 200 ms; FIFO of 2, oldest cancelled; nothing starts in Low Power Mode on battery or at memory
/// pressure warning or worse, and critical pressure cancels the held prewarms (Chrome's speculation rules:
/// anchor_element_interaction_tracker.cc, prerender_host_registry.cc).
@MainActor @Suite(.timeLimit(.minutes(1)))
struct IntentPrewarmServiceTests {
    /// The content owner: which targets are cold, and what was started and cancelled, in order.
    final class Warmer: IntentPrewarmWarming {
        var cold: Set<String> = ["a", "b", "c", "d"]
        var started: [String] = []
        var triggers: [IntentPrewarmTrigger] = []
        var cancelled: [String] = []

        func isCold(_ target: String) -> Bool { cold.contains(target) }

        func startPrewarm(_ target: String, trigger: IntentPrewarmTrigger) {
            started.append(target)
            triggers.append(trigger)
        }

        func cancelPrewarm(_ target: String) { cancelled.append(target) }
    }

    /// A service whose dwell is a background `MainDeadline` on a deadline rig the test fires, and a pressure
    /// source the test drives.
    struct Rig {
        let warmer = Warmer()
        let deadlines = IntentPrewarmDeadlineRig()
        let pressure = ManualMemoryPressureSource()
        let dwell: MainDeadline
        let service: IntentPrewarmService<String>

        init(power: IntentPrewarmPower = IntentPrewarmPower()) {
            dwell = MainDeadline(owner: "IntentPrewarm.hoverDwell", workClass: .background, scheduler: deadlines.scheduler)
            service = IntentPrewarmService(warmer: warmer, memoryPressure: MemoryPressureEvents(source: pressure),
                                           dwellTimer: dwell, power: power)
        }
    }

    // MARK: Dwell

    @Test func idleAndWarmTargetsHoldNoTimer() {
        let rig = Rig()
        #expect(!rig.service.isDwelling)
        rig.warmer.cold = []
        rig.service.pointerHovered("a")
        #expect(!rig.service.isDwelling, "a warm target has nothing to prewarm")
        rig.service.pointerHovered(nil)
        #expect(!rig.service.isDwelling)
        #expect(rig.warmer.started.isEmpty)
    }

    @Test func restingOnAColdTargetPrewarmsItAfterTheDwell() throws {
        let rig = Rig()
        #expect(rig.service.dwell == .milliseconds(200))
        rig.service.pointerHovered("a")
        let armed = try #require(rig.dwell.plannedWake)
        rig.service.pointerHovered("a")
        rig.service.pointerHovered("a")
        #expect(rig.service.isDwelling)
        #expect(armed.due == .milliseconds(200), "the dwell is 200 ms from the hover")
        #expect(rig.dwell.plannedWake?.due == armed.due, "repeated deliveries on one target keep its one deadline")
        #expect(armed.fire >= .milliseconds(200), "never sooner than the dwell")

        rig.deadlines.advance(to: .milliseconds(199))
        rig.deadlines.fire(movingTime: false)
        #expect(rig.warmer.started.isEmpty, "199 ms is not a dwell")
        #expect(rig.service.isDwelling)

        rig.deadlines.fire()
        #expect(rig.warmer.started == ["a"])
        #expect(rig.warmer.triggers == [.hoverDwell])
        #expect(rig.service.queue.held == ["a"])
        #expect(!rig.service.isDwelling, "the deadline is gone once it fired")
        #expect(rig.service.counters.started[.hoverDwell] == 1)

        rig.service.pointerHovered(nil)
        rig.service.pointerHovered("a")
        #expect(!rig.service.isDwelling, "a held target is not warmed twice")
    }

    @Test func leavingTheTargetCancelsTheDwell() {
        let rig = Rig()
        rig.service.pointerHovered("a")
        rig.service.pointerHovered(nil)
        #expect(!rig.service.isDwelling)
        #expect(rig.service.restingTarget == nil)
        rig.deadlines.fire()
        #expect(rig.warmer.started.isEmpty)
    }

    @Test func anotherTargetRestartsTheOneDeadline() {
        let rig = Rig()
        rig.service.pointerHovered("a")
        rig.deadlines.advance(to: .milliseconds(150))
        rig.service.pointerHovered("b")
        #expect(rig.service.isDwelling)
        #expect(rig.service.restingTarget == "b")
        #expect(rig.dwell.plannedWake?.due == .milliseconds(350), "the dwell starts again on b")
        rig.deadlines.fire()
        #expect(rig.warmer.started == ["b"], "the dwell on a was cancelled by the move to b")
    }

    @Test func aPressCancelsTheDwellUntilThePointerMovesOn() {
        let rig = Rig()
        rig.service.pointerHovered("a")
        rig.service.pointerPressed()
        #expect(!rig.service.isDwelling)
        rig.service.pointerHovered("a")
        #expect(!rig.service.isDwelling, "the same target after a press does not re-arm")
        rig.service.pointerHovered("b")
        #expect(rig.service.isDwelling)
    }

    @Test func theServiceHoldsItsWarmerWeakly() throws {
        var warmer: Warmer? = Warmer()
        weak var watched = warmer
        let deadlines = IntentPrewarmDeadlineRig()
        let timer = MainDeadline(owner: "IntentPrewarm.hoverDwell", workClass: .background, scheduler: deadlines.scheduler)
        let service = IntentPrewarmService(warmer: try #require(warmer), memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                                           dwellTimer: timer)
        warmer = nil
        #expect(watched == nil, "the content owner may own the service: no cycle")
        service.pointerHovered("a")
        #expect(!service.isDwelling, "a released warmer leaves nothing cold")
        service.prewarm("b", trigger: .pointerDown)
        #expect(service.queue.held.isEmpty)
    }


    @Test func forgettingATargetDropsItWithNoCancel() {
        let rig = Rig()
        rig.service.prewarm("a", trigger: .pointerDown)
        rig.service.pointerHovered("b")
        rig.service.forget("a")
        rig.service.forget("b")
        #expect(rig.service.queue.held.isEmpty)
        #expect(!rig.service.isDwelling)
        #expect(rig.service.restingTarget == nil)
        #expect(rig.warmer.cancelled.isEmpty)
        #expect(rig.service.counters.used == 0)
    }

    @Test func committingTheRestingTargetCancelsItsDwell() {
        let rig = Rig()
        rig.service.pointerHovered("a")
        rig.service.committed("a")
        #expect(!rig.service.isDwelling)
    }

    // MARK: Power

    @Test func lowPowerModeOnBatteryStartsNothing() {
        let rig = Rig(power: IntentPrewarmPower(lowPowerMode: true, onBattery: true))
        rig.service.pointerHovered("a")
        #expect(!rig.service.isDwelling)
        rig.service.prewarm("b", trigger: .pointerDown)
        #expect(rig.warmer.started.isEmpty)
        #expect(rig.service.counters.skippedForPower == 2)
    }

    @Test func lowPowerModeOnACOrBatteryAloneStillPrewarms() {
        let onAC = Rig(power: IntentPrewarmPower(lowPowerMode: true, onBattery: false))
        onAC.service.pointerHovered("a")
        #expect(onAC.service.isDwelling)
        let onBattery = Rig(power: IntentPrewarmPower(lowPowerMode: false, onBattery: true))
        onBattery.service.prewarm("a", trigger: .pointerDown)
        #expect(onBattery.warmer.started == ["a"])
    }

    @Test func enteringLowPowerModeOnBatteryCancelsTheDwell() {
        let rig = Rig()
        rig.service.pointerHovered("a")
        rig.service.prewarm("b", trigger: .pointerDown)
        rig.service.power = IntentPrewarmPower(lowPowerMode: true, onBattery: true)
        #expect(!rig.service.isDwelling)
        #expect(rig.service.queue.held == ["b"], "held prewarms stay until evicted or used")
        #expect(rig.warmer.cancelled.isEmpty)
    }

    // MARK: Memory pressure

    @Test func memoryPressureWarningStartsNothingAndCancelsTheDwell() {
        let rig = Rig()
        rig.service.prewarm("b", trigger: .pointerDown)
        rig.service.pointerHovered("a")
        rig.pressure.send(.warning)
        #expect(!rig.service.isDwelling)
        #expect(rig.service.queue.held == ["b"], "warning keeps the held prewarms")

        rig.service.pointerHovered("c")
        #expect(!rig.service.isDwelling)
        rig.service.prewarm("d", trigger: .pointerDown)
        #expect(rig.warmer.started == ["b"])
        #expect(rig.service.counters.skippedForPressure == 2)

        rig.pressure.send(.normal)
        rig.service.pointerHovered("a")
        #expect(rig.service.isDwelling, "normal pressure prewarms again")
    }

    @Test func criticalMemoryPressureCancelsTheHeldPrewarms() {
        let rig = Rig()
        rig.service.prewarm("a", trigger: .pointerDown)
        rig.service.prewarm("b", trigger: .pointerDown)
        rig.pressure.send(.critical)
        #expect(rig.service.queue.held.isEmpty)
        #expect(rig.warmer.cancelled == ["a", "b"])
        #expect(rig.service.counters.cancelledByPressure == 2)
    }

    // MARK: FIFO

    @Test func theFIFOHoldsTwoAndEvictsTheOldest() {
        let rig = Rig()
        #expect(rig.service.queue.limit == 2)
        rig.service.prewarm("a", trigger: .pointerDown)
        rig.service.prewarm("b", trigger: .hoverDwell)
        rig.service.prewarm("b", trigger: .hoverDwell)
        #expect(rig.warmer.started == ["a", "b"], "a held target is not started twice")
        rig.service.prewarm("c", trigger: .pointerDown)
        #expect(rig.service.queue.held == ["b", "c"])
        #expect(rig.warmer.cancelled == ["a"])
        #expect(rig.service.counters.evicted == 1)
    }

    @Test func aCommittedPrewarmIsUsedNotCancelled() {
        let rig = Rig()
        rig.service.prewarm("a", trigger: .pointerDown)
        rig.service.committed("a")
        #expect(rig.service.queue.held.isEmpty)
        #expect(rig.warmer.cancelled.isEmpty)
        #expect(rig.service.counters.used == 1)
    }
}
