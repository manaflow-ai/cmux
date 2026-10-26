import CmuxNextCompat
import CmuxNextInput
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Hover-dwell prewarm (p04-input-043): one DemandTimer, pending only while the pointer rests on a cold
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
        /// Runs once at the next start (a test awaiting the dwell's fire).
        var onStart: (() -> Void)?

        func isCold(_ target: String) -> Bool { cold.contains(target) }

        func startPrewarm(_ target: String, trigger: IntentPrewarmTrigger) {
            started.append(target)
            triggers.append(trigger)
            let onStart = onStart
            self.onStart = nil
            onStart?()
        }

        func cancelPrewarm(_ target: String) { cancelled.append(target) }
    }

    /// A service on a manual clock and a pressure source the test drives.
    struct Rig {
        let warmer = Warmer()
        let clock = ManualClock()
        let pressure = ManualMemoryPressureSource()
        let events: MemoryPressureEvents
        let service: IntentPrewarmService<String>

        init(power: IntentPrewarmPower = IntentPrewarmPower()) {
            events = MemoryPressureEvents(source: pressure)
            let timer = DemandTimer(owner: "IntentPrewarm.hoverDwell", clock: clock, ledger: WakeupLedger())
            service = IntentPrewarmService(warmer: warmer, memoryPressure: events, dwellTimer: timer, power: power)
        }

        /// Moves the clock past the dwell and returns once the dwell's prewarm started.
        func fireDwell() async throws {
            try await clock.waitForSleeper()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                warmer.onStart = { continuation.resume() }
                clock.advance(by: .milliseconds(200))
            }
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

    @Test func restingOnAColdTargetPrewarmsItAfterTheDwell() async throws {
        let rig = Rig()
        #expect(rig.service.dwell == .milliseconds(200))
        rig.service.pointerHovered("a")
        rig.service.pointerHovered("a")
        rig.service.pointerHovered("a")
        #expect(rig.service.isDwelling)
        try await rig.clock.waitForSleeper()
        #expect(rig.clock.sleepRequests.count == 1, "per-frame deliveries on one target keep its one deadline")
        rig.clock.advance(by: .milliseconds(199))
        #expect(rig.warmer.started.isEmpty)

        try await rig.fireDwell()
        #expect(rig.warmer.started == ["a"])
        #expect(rig.warmer.triggers == [.hoverDwell])
        #expect(rig.service.prewarmed == ["a"])
        #expect(!rig.service.isDwelling, "the timer is gone once it fired")
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
    }

    @Test func anotherTargetRestartsTheOneTimer() async throws {
        let rig = Rig()
        rig.service.pointerHovered("a")
        rig.service.pointerHovered("b")
        #expect(rig.service.isDwelling)
        #expect(rig.service.restingTarget == "b")
        try await rig.fireDwell()
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
        #expect(rig.service.prewarmed == ["b"], "held prewarms stay until evicted or used")
        #expect(rig.warmer.cancelled.isEmpty)
    }

    // MARK: Memory pressure

    @Test func memoryPressureWarningStartsNothingAndCancelsTheDwell() {
        let rig = Rig()
        rig.service.prewarm("b", trigger: .pointerDown)
        rig.service.pointerHovered("a")
        rig.pressure.send(.warning)
        #expect(!rig.service.isDwelling)
        #expect(rig.service.prewarmed == ["b"], "warning keeps the held prewarms")

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
        #expect(rig.service.prewarmed.isEmpty)
        #expect(rig.warmer.cancelled == ["a", "b"])
        #expect(rig.service.counters.cancelledByPressure == 2)
    }

    // MARK: FIFO

    @Test func theFIFOHoldsTwoAndEvictsTheOldest() {
        let rig = Rig()
        #expect(rig.service.fifoLimit == 2)
        rig.service.prewarm("a", trigger: .pointerDown)
        rig.service.prewarm("b", trigger: .hoverDwell)
        rig.service.prewarm("b", trigger: .hoverDwell)
        #expect(rig.warmer.started == ["a", "b"], "a held target is not started twice")
        rig.service.prewarm("c", trigger: .pointerDown)
        #expect(rig.service.prewarmed == ["b", "c"])
        #expect(rig.warmer.cancelled == ["a"])
        #expect(rig.service.counters.evicted == 1)
    }

    @Test func aCommittedPrewarmIsUsedNotCancelled() {
        let rig = Rig()
        rig.service.prewarm("a", trigger: .pointerDown)
        rig.service.committed("a")
        #expect(rig.service.prewarmed.isEmpty)
        #expect(rig.warmer.cancelled.isEmpty)
        #expect(rig.service.counters.used == 1)
    }
}
