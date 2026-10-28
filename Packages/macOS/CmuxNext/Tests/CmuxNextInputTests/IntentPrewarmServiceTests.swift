import CmuxNextCompat
import CmuxNextInput
import CmuxNextInputCore
import CmuxNextInputDiagnostics
import CmuxNextWakeups
import Testing

/// Hover-dwell prewarm and pointer-down prewarm (a press on a row that
/// commits on its release is admitted to the same FIFO on its turn and its work starts on a background-class
/// deadline at zero, never on the press's turn): one dwell MainDeadline, pending only while the pointer rests on a cold
/// target, restarted on another target and cancelled on nothing, a press or a commit; the prewarm starts
/// after 200 ms; FIFO of 2, oldest cancelled; nothing starts in Low Power Mode on battery or at memory
/// pressure warning or worse, and critical pressure cancels the held prewarms (Chrome's speculation rules:
/// anchor_element_interaction_tracker.cc, prerender_host_registry.cc).
///
/// Key steps: a next/previous key's prewarm of the following item is one background-class
/// deadline, never run in the key's turn; three presses prewarm items 2, 3, 4 in order through the FIFO of 2;
/// a step the other way cancels the old direction's key-step prewarms.
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

    /// A service whose dwell, key step and press start are background `MainDeadline`s on a deadline rig the test
    /// fires, and a pressure source the test drives.
    struct Rig {
        let warmer = Warmer()
        let deadlines = IntentPrewarmDeadlineRig()
        let pressure = ManualMemoryPressureSource()
        let dwell: MainDeadline
        let step: MainDeadline
        let pressStart: MainDeadline
        let service: IntentPrewarmService<String>

        init(power: IntentPrewarmPower = IntentPrewarmPower(), hovers: Bool = true, steps: Bool = true, presses: Bool = true) {
            dwell = MainDeadline(owner: "IntentPrewarm.hoverDwell", workClass: .background, scheduler: deadlines.scheduler)
            step = MainDeadline(owner: "IntentPrewarm.keyStep", workClass: .background, scheduler: deadlines.scheduler)
            pressStart = MainDeadline(owner: "IntentPrewarm.pressStart", workClass: .background, scheduler: deadlines.scheduler)
            service = IntentPrewarmService(warmer: warmer, memoryPressure: MemoryPressureEvents(source: pressure),
                                           dwellTimer: hovers ? dwell : nil, stepTimer: steps ? step : nil,
                                           pressStart: presses ? pressStart : nil, power: power)
        }

        /// A press on `target`, then the press deadline's frame.
        func press(_ target: String?) {
            service.pointerPressed(on: target)
            deadlines.fire()
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

    // MARK: Pointer down

    /// The press's turn admits and counts; the warmer's work runs only once the background-class press
    /// deadline fires, at zero (no dwell): the press-to-release time is the head start.
    @Test func aPressAdmitsOnItsTurnAndStartsTheWorkOnTheBackgroundDeadline() throws {
        let rig = Rig()
        rig.service.pointerPressed(on: "a")
        #expect(rig.warmer.started.isEmpty, "the warmer ran inside the press's input turn")
        #expect(rig.service.queue.held == ["a"], "the FIFO admit is on the press's turn")
        #expect(rig.service.counters.started == [.pointerDown: 1])
        let wake = try #require(rig.pressStart.plannedWake)
        #expect(wake.due == .zero, "the start waits for no dwell")
        #expect(rig.pressStart.workClass == .background)
        #expect(!rig.service.isDwelling)

        rig.deadlines.fire()
        #expect(rig.warmer.started == ["a"])
        #expect(rig.warmer.triggers == [.pointerDown])
        #expect(!rig.pressStart.isScheduled)
        #expect(rig.warmer.cancelled.isEmpty, "a prewarm only starts work: nothing else reaches the content owner")
    }

    @Test func twoPressesBeforeTheDeadlineStartBothInOneFrameOldestFirst() {
        let rig = Rig()
        rig.service.pointerPressed(on: "a")
        rig.service.pointerPressed(on: "b")
        #expect(rig.warmer.started.isEmpty)
        rig.deadlines.fire()
        #expect(rig.warmer.started == ["a", "b"])
    }

    @Test func aCommitBeforeThePressDeadlineStartsNothingAndCountsNoHit() {
        let rig = Rig()
        rig.service.pointerPressed(on: "a")
        rig.service.committed("a")
        #expect(!rig.pressStart.isScheduled, "nothing is left to start")
        rig.deadlines.fire()
        #expect(rig.warmer.started.isEmpty)
        #expect(rig.service.queue.held.isEmpty)
        #expect(rig.service.counters.used == 0 && rig.service.counters.hits.isEmpty, "a prewarm that never ran is no hit")
    }

    @Test func anUnstartedPressPrewarmEvictedBeforeItsDeadlineIsNotCancelled() {
        let rig = Rig()
        rig.service.pointerPressed(on: "a")
        rig.service.pointerPressed(on: "b")
        rig.service.pointerPressed(on: "c")
        #expect(rig.service.queue.held == ["b", "c"])
        #expect(rig.service.counters.evicted == 1)
        rig.deadlines.fire()
        #expect(rig.warmer.started == ["b", "c"], "the evicted press never starts")
        #expect(rig.warmer.cancelled.isEmpty, "nothing ran for it, so nothing is cancelled")
    }

    /// The release landed elsewhere and the page slept again by the hibernation's grace: the spent prewarm
    /// leaves the FIFO, so the next press on that cold row prewarms it again and the stale entry is no hit.
    @Test func aPrewarmWhosePageSleptAgainLeavesTheFIFOAndAPressStartsItAgain() {
        let rig = Rig()
        rig.press("a")
        rig.service.cooled("a")
        #expect(rig.service.queue.held.isEmpty, "the stale entry still holds a slot")
        #expect(rig.warmer.cancelled.isEmpty, "a cooled prewarm is not cancelled")
        #expect(rig.service.counters.used == 0, "nor used")
        rig.press("a")
        #expect(rig.warmer.started == ["a", "a"], "the press on the cold row did not prewarm it again")
        #expect(rig.service.counters.started == [.pointerDown: 2])
        rig.service.committed("a")
        #expect(rig.service.counters.hits == [.pointerDown: 1], "only the second prewarm is a hit")
    }

    @Test func aPageThatSleepsBeforeThePressDeadlineStartsNothing() {
        let rig = Rig()
        rig.service.pointerPressed(on: "a")
        rig.service.cooled("a")
        rig.deadlines.fire()
        #expect(rig.warmer.started.isEmpty)
        #expect(rig.service.queue.held.isEmpty)
    }

    @Test func aPressThatCommitsOnThePressPrewarmsNothingAndEndsTheDwell() {
        let rig = Rig()
        rig.service.pointerHovered("a")
        rig.service.pointerPressed(on: nil)
        #expect(!rig.service.isDwelling)
        rig.deadlines.fire()
        #expect(rig.warmer.started.isEmpty)
        #expect(rig.service.queue.held.isEmpty)
    }

    @Test func aPressOnAWarmOrHeldTargetStartsNothing() {
        let rig = Rig()
        rig.warmer.cold = ["b"]
        rig.press("a")
        #expect(rig.warmer.started.isEmpty, "a warm page has nothing to prewarm")
        rig.press("b")
        rig.press("b")
        #expect(rig.warmer.started == ["b"], "a held target is not started twice")
        #expect(rig.service.counters.started == [.pointerDown: 1])
    }

    @Test func pressesShareTheFIFOOfTwoWithTheHoverDwell() {
        let rig = Rig()
        rig.service.pointerHovered("a")
        rig.deadlines.fire()
        rig.service.pointerPressed(on: "b")
        rig.press("c")
        #expect(rig.warmer.started == ["a", "b", "c"])
        #expect(rig.service.queue.held == ["b", "c"], "one FIFO for both triggers, oldest out")
        #expect(rig.warmer.cancelled == ["a"])
        #expect(rig.service.counters.evicted == 1)
    }

    @Test func aPressPrewarmKeptAfterAReleaseElsewhereStaysUntilEvictedOrUsed() {
        let rig = Rig()
        rig.press("a")
        rig.service.pointerHovered("b")
        rig.service.pointerHovered(nil)
        #expect(rig.service.queue.held == ["a"], "no cancel when the release lands off the row")
        #expect(rig.warmer.cancelled.isEmpty)
        rig.service.committed("a")
        #expect(rig.service.counters.used == 1)
    }

    @Test func hitsAreCountedByTheTriggerThatStartedThePrewarm() {
        let rig = Rig()
        rig.service.pointerHovered("a")
        rig.deadlines.fire()
        rig.press("b")
        rig.service.committed("b")
        rig.service.committed("a")
        rig.service.committed("c")
        #expect(rig.service.counters.used == 2)
        #expect(rig.service.counters.hits == [.hoverDwell: 1, .pointerDown: 1], "press hits apart from hover hits")
        rig.service.resetCounters()
        #expect(rig.service.counters == IntentPrewarmCounters())
    }

    @Test func onlyTheEnabledTriggersStartPrewarms() {
        let pressOnly = Rig(hovers: false, steps: false)
        pressOnly.service.pointerHovered("a")
        #expect(!pressOnly.service.isDwelling, "intentPrewarmHover off: a hover arms nothing")
        pressOnly.press("a")
        #expect(pressOnly.warmer.started == ["a"])

        let hoverOnly = Rig(steps: false, presses: false)
        hoverOnly.press("a")
        #expect(hoverOnly.warmer.started.isEmpty, "intentPrewarmPress off: a press prewarms nothing")
        hoverOnly.service.pointerHovered("a")
        #expect(hoverOnly.service.isDwelling)
    }

    @Test func aPressInLowPowerModeOnBatteryOrUnderPressureStartsNothing() {
        let battery = Rig(power: IntentPrewarmPower(lowPowerMode: true, onBattery: true))
        battery.press("a")
        #expect(battery.warmer.started.isEmpty)
        #expect(battery.service.counters.skippedForPower == 1)

        let pressured = Rig()
        pressured.pressure.send(.warning)
        pressured.press("a")
        #expect(pressured.warmer.started.isEmpty)
        #expect(pressured.service.counters.skippedForPressure == 1)
    }

    /// `debug.input` section `prewarm` reads the live service's counters in one main-actor copy and
    /// `reset` starts them over; without a service it reads zeros.
    @Test func theDebugInputSectionReadsAndResetsTheServicesCounters() async {
        let rig = Rig()
        rig.press("a")
        rig.service.committed("a")
        rig.press("b")
        let service = rig.service
        let source = IntentPrewarmDebugSource { service }
        let section = await source.read()
        #expect(section.started == ["pointerDown": 2])
        #expect(section.hits == ["pointerDown": 1])
        #expect(section.held == 1)
        await source.reset()
        #expect(rig.service.counters == IntentPrewarmCounters())
        #expect(rig.service.queue.held == ["b"], "a reset keeps the held prewarms")

        let absent = IntentPrewarmDebugSource { () -> IntentPrewarmService<String>? in nil }
        #expect(await absent.read() == DebugInputPrewarm(counters: IntentPrewarmCounters(), held: 0))
    }

    @Test func theServiceHoldsItsWarmerWeakly() throws {
        var warmer: Warmer? = Warmer()
        weak var watched = warmer
        let deadlines = IntentPrewarmDeadlineRig()
        let timer = MainDeadline(owner: "IntentPrewarm.hoverDwell", workClass: .background, scheduler: deadlines.scheduler)
        let pressStart = MainDeadline(owner: "IntentPrewarm.pressStart", workClass: .background, scheduler: deadlines.scheduler)
        let service = IntentPrewarmService(warmer: try #require(warmer), memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                                           dwellTimer: timer, pressStart: pressStart)
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

    @Test func criticalPressureDropsAnUnstartedPressPrewarmWithNoCancel() {
        let rig = Rig()
        rig.service.pointerPressed(on: "a")
        rig.pressure.send(.critical)
        #expect(!rig.pressStart.isScheduled)
        rig.deadlines.fire()
        #expect(rig.warmer.started.isEmpty)
        #expect(rig.warmer.cancelled.isEmpty)
        #expect(rig.service.counters.cancelledByPressure == 1)
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

    // MARK: Key steps

    @Test func aKeyStepsPrewarmRunsAtTheBackgroundClassNeverInTheKeysTurn() {
        let rig = Rig()
        var reads = 0
        rig.service.stepped(.forward) {
            reads += 1
            return ["b"]
        }
        #expect(rig.step.workClass == .background)
        #expect(rig.service.isStepPending)
        #expect(reads == 0, "the following item is not even read in the key's turn")
        #expect(rig.warmer.started.isEmpty, "the prewarm ran in the key's turn")

        rig.deadlines.fire()
        #expect(reads == 1)
        #expect(rig.warmer.started == ["b"])
        #expect(rig.warmer.triggers == [.keyStep])
        #expect(rig.service.counters.started[.keyStep] == 1)
        #expect(!rig.service.isStepPending)
        #expect(rig.service.stepDirection == .forward)
    }

    @Test func threePressesPrewarmItemsTwoThreeFourInOrderWithAFIFOOfTwo() {
        let rig = Rig()
        rig.warmer.cold = ["1", "2", "3", "4"]
        for item in 1...3 {
            rig.service.committed("\(item)") // the press showed item `item`
            rig.service.stepped(.forward) { ["\(item + 1)"] }
            #expect(rig.service.queue.held.count <= 2)
            rig.deadlines.fire()
        }
        #expect(rig.warmer.started == ["2", "3", "4"])
        #expect(rig.service.counters.used == 2, "presses two and three landed on prewarmed items")
        #expect(rig.service.queue.held == ["4"])
        #expect(rig.warmer.cancelled.isEmpty)
    }

    @Test func keyStepsPastUnshownItemsEvictTheOldestOfTwo() {
        let rig = Rig()
        rig.warmer.cold = ["2", "3", "4"]
        for item in 2...4 {
            rig.service.stepped(.forward) { ["\(item)"] }
            rig.deadlines.fire()
        }
        #expect(rig.warmer.started == ["2", "3", "4"])
        #expect(rig.service.queue.held == ["3", "4"])
        #expect(rig.warmer.cancelled == ["2"])
        #expect(rig.service.counters.evicted == 1)
    }

    @Test func aStepTheOtherWayCancelsTheOldDirectionsPrewarms() {
        let rig = Rig()
        rig.service.prewarm("c", trigger: .hoverDwell)
        rig.service.stepped(.forward) { ["b"] }
        rig.deadlines.fire()
        #expect(rig.service.queue.held == ["c", "b"])

        rig.service.stepped(.backward) { ["a"] }
        #expect(rig.warmer.cancelled == ["b"], "the forward prewarm goes at the backward key, in its turn")
        #expect(rig.service.queue.held == ["c"], "a hover's prewarm is not the old direction's")
        #expect(rig.service.counters.cancelledByDirection == 1)
        rig.deadlines.fire()
        #expect(rig.warmer.started == ["c", "b", "a"])
        #expect(rig.service.queue.held == ["c", "a"])
        #expect(rig.service.stepDirection == .backward)
    }

    @Test func aKeyStepTargetEvictedThenHoveredAgainIsTheHoversNotTheDirections() {
        let rig = Rig()
        rig.warmer.cold = ["x", "h1", "h2"]
        rig.service.stepped(.forward) { ["x"] }
        rig.deadlines.fire()
        rig.service.prewarm("h1", trigger: .hoverDwell)
        rig.service.prewarm("h2", trigger: .hoverDwell)
        #expect(rig.service.queue.held == ["h1", "h2"], "the hovers evicted the key step's x")
        rig.service.prewarm("x", trigger: .hoverDwell)
        #expect(rig.service.queue.held == ["h2", "x"])
        let cancelledBefore = rig.warmer.cancelled

        rig.service.stepped(.backward) { [] }
        #expect(rig.warmer.cancelled == cancelledBefore, "the hover's x is no key step's")
        #expect(rig.service.queue.held == ["h2", "x"])
        #expect(rig.service.counters.cancelledByDirection == 0)
    }

    @Test func aCommittedOrForgottenKeyStepTargetHoveredAgainIsNotCancelledByDirection() {
        let rig = Rig()
        rig.warmer.cold = ["x", "y"]
        rig.service.stepped(.forward) { ["x", "y"] }
        rig.deadlines.fire()
        rig.service.committed("x")
        rig.service.forget("y")
        rig.service.prewarm("x", trigger: .hoverDwell)
        rig.service.prewarm("y", trigger: .pointerDown)

        rig.service.stepped(.backward) { [] }
        #expect(rig.warmer.cancelled.isEmpty)
        #expect(rig.service.queue.held == ["x", "y"])
        #expect(rig.service.counters.cancelledByDirection == 0)
    }

    @Test func aStepTheOtherWayDropsTheOldDirectionsPendingStep() {
        let rig = Rig()
        rig.service.stepped(.forward) { ["b"] }
        rig.service.stepped(.backward) { ["a"] }
        rig.deadlines.fire()
        #expect(rig.warmer.started == ["a"])
        #expect(rig.warmer.cancelled.isEmpty, "nothing had started forward")
    }

    @Test func aRepeatedKeyKeepsOnlyItsLatestPendingStep() {
        let rig = Rig()
        rig.service.stepped(.forward) { ["b"] }
        rig.service.stepped(.forward) { ["c"] }
        rig.deadlines.fire()
        #expect(rig.warmer.started == ["c"], "a repeat before the background run replaces the step")
    }

    @Test func aWarmOrHeldFollowingItemStartsNothing() {
        let rig = Rig()
        rig.warmer.cold = ["b"]
        rig.service.prewarm("b", trigger: .hoverDwell)
        rig.service.stepped(.forward) { ["b", "x", "b"] }
        rig.deadlines.fire()
        #expect(rig.warmer.started == ["b"], "b was held already and x is awake")
        rig.service.stepped(.backward) { [] }
        #expect(rig.warmer.cancelled.isEmpty, "the hover's b is no key step's")
    }

    @Test func keyStepsStartNothingInLowPowerModeOnBatteryOrUnderPressure() {
        let rig = Rig(power: IntentPrewarmPower(lowPowerMode: true, onBattery: true))
        rig.service.stepped(.forward) { ["b"] }
        #expect(!rig.service.isStepPending)
        #expect(rig.service.counters.skippedForPower == 1)

        rig.service.power = IntentPrewarmPower()
        rig.service.stepped(.forward) { ["b"] }
        #expect(rig.service.isStepPending)
        rig.pressure.send(.warning)
        #expect(!rig.service.isStepPending, "pressure drops the pending step")
        rig.service.stepped(.forward) { ["b"] }
        #expect(!rig.service.isStepPending)
        #expect(rig.service.counters.skippedForPressure == 1)
        rig.deadlines.fire()
        #expect(rig.warmer.started.isEmpty)
    }

    @Test func criticalPressureForgetsTheKeyStepsItCancelled() {
        let rig = Rig()
        rig.service.stepped(.forward) { ["b"] }
        rig.deadlines.fire()
        rig.pressure.send(.critical)
        #expect(rig.warmer.cancelled == ["b"])
        rig.pressure.send(.normal)
        rig.service.stepped(.backward) { [] }
        #expect(rig.warmer.cancelled == ["b"], "a cancelled prewarm is not cancelled twice")
        #expect(rig.service.counters.cancelledByDirection == 0)
    }

    @Test func eachTriggerRunsOnlyWithItsDeadline() {
        let stepsOnly = Rig(hovers: false)
        stepsOnly.service.pointerHovered("a")
        #expect(!stepsOnly.service.isDwelling, "no dwell deadline: intentPrewarmHover is off")
        #expect(stepsOnly.service.restingTarget == nil)

        let hoversOnly = Rig(steps: false)
        hoversOnly.service.stepped(.forward) { ["b"] }
        #expect(!hoversOnly.service.isStepPending, "no step deadline: directionalPrewarm is off")
        #expect(hoversOnly.service.stepDirection == nil)
        hoversOnly.deadlines.fire()
        #expect(hoversOnly.warmer.started.isEmpty)
    }

    @Test func aStepsDirectionComesFromItsOffset() {
        #expect(IntentPrewarmDirection(offset: 1) == .forward)
        #expect(IntentPrewarmDirection(offset: -3) == .backward)
        #expect(IntentPrewarmDirection(offset: 0) == nil)
    }
}
