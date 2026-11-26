import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Lever 4e (`CMUX_NEXT_CEF_PUMP_AT_STEP=1`): a window live resize keeps the main thread in cmux's steps, and the
/// pump's timer got about 10 passes a second (window corner drags, Chromium trace: bursts of browser-main tasks every
/// 91 ms p50, against every 8.3 ms in a divider drag), so each page's ack of its new size waited 55 ms p50 and its next
/// size waited in Chromium's resize IPC throttle. The pump now also runs at each step's start the work CEF already
/// asked for: a request whose deadline passed, or an immediate one still on its way from a Chromium thread; never
/// re-entrantly, never work CEF did not ask for.
@MainActor
@Suite struct CEFPumpAtStepTests {
    typealias Timer = CEFPumpCrossThreadGateTests.Timer
    typealias Clock = CEFPumpCrossThreadGateTests.Clock

    final class Box {
        var runs = 0
        var pump: CEFMessagePump?
        var inner: [String?] = []
        var late: [String] = []
    }

    struct Rig {
        let pump: CEFMessagePump
        let timer: Timer
        let clock: Clock
        let gate: CEFPumpCrossThreadGate
    }

    /// A running demand-driven pump (no safety net) after its start's pass, its work counted in `box`.
    static func rig(_ box: Box, onlyAtSteps: Bool = false, work: @escaping () -> Void = {}) -> Rig {
        let timer = Timer()
        let clock = Clock()
        let gate = CEFPumpCrossThreadGate(ledger: WakeupLedger())
        let pump = CEFMessagePump(work: { box.runs += 1; work() }, safetyNet: .none, timer: timer, clock: { clock.seconds },
                                  ledger: WakeupLedger(), gate: gate, defersToSteps: onlyAtSteps)
        pump.onDeferredPassOutsideStep = { ms, why in box.late.append(String(format: "%@ %.1f", why, ms)) }
        box.pump = pump
        pump.start()
        timer.fire()
        box.runs = 0
        box.inner = []
        return Rig(pump: pump, timer: timer, clock: clock, gate: gate)
    }

    @Test func aStepRunsTheWorkCEFAskedForNowOnce() {
        let box = Box()
        let rig = Self.rig(box)
        rig.pump.request(milliseconds: 0)  // armed; the timer has not fired (a busy live resize)
        #expect(rig.pump.runIfDueAtStep() == " ran=1")
        #expect(box.runs == 1)
        #expect(rig.pump.runIfDueAtStep() == nil, "nothing is due after the pass")
        #expect(box.runs == 1)
        #expect(rig.pump.stats.stepRuns == 1)
        #expect(rig.pump.stats.stepNotDue == 1)
    }

    @Test func aDelayedRequestRunsOnlyOnceItsDeadlinePassed() {
        let box = Box()
        let rig = Self.rig(box)
        rig.pump.request(milliseconds: 10)
        #expect(rig.pump.runIfDueAtStep() == nil, "CEF asked for work in 10 ms, not now")
        #expect(box.runs == 0)
        rig.clock.seconds += 0.011
        #expect(rig.pump.runIfDueAtStep() == " ran=1")
        #expect(box.runs == 1)
    }

    @Test func anImmediateRequestOnItsWayFromAChromiumThreadIsDue() {
        let box = Box()
        let rig = Self.rig(box)
        rig.gate.immediatePosted()  // posted to the main run loop, its block not run yet
        #expect(rig.pump.runIfDueAtStep() == " ran=1 in_flight=1")
        #expect(box.runs == 1)
        rig.gate.immediateDelivered()
        #expect(rig.pump.runIfDueAtStep() == nil)
    }

    @Test func aStepInsideAPassRunsNothing() {
        let box = Box()
        let rig = Self.rig(box) { box.inner.append(box.pump?.runIfDueAtStep()) }
        let skipped = rig.pump.stats.stepSkippedInPass
        rig.pump.request(milliseconds: 0)
        rig.timer.fire()
        #expect(box.runs == 1)
        #expect(box.inner == [nil], "a step begun from a CEF callback inside the pass runs no pass of its own")
        #expect(rig.pump.stats.stepSkippedInPass == skipped + 1)
    }

    @Test func aStoppedPumpRunsNothing() {
        let box = Box()
        let rig = Self.rig(box)
        rig.pump.request(milliseconds: 0)
        rig.pump.stop()
        #expect(rig.pump.runIfDueAtStep() == nil)
        #expect(box.runs == 0)
    }

    // Its steps-only form (`CMUX_NEXT_CEF_PUMP_AT_STEP=steps`): with every page drawing each size, the timer ran Chromium's
    // work between the steps too (about 36 passes a second in a corner drag), so a pointer event waited longer for its
    // step (input age p50 10 ms with the timer alone, 18-27 ms with both). While a live resize steps, a timer pass now
    // waits for the next step's start, at most 16 ms; the resize's end runs one it held.

    /// A live resize: a step began, and CEF asked for work now 2 ms later (the clock at 100.002 s).
    static func stepping(_ rig: Rig) {
        #expect(rig.pump.runIfDueAtStep() == nil, "the step's start: nothing is due yet")
        rig.clock.seconds += 0.002
        rig.pump.request(milliseconds: 0)
    }

    @Test func inALiveResizeTheTimersPassWaitsForTheNextStep() throws {
        let box = Box()
        let rig = Self.rig(box, onlyAtSteps: true)
        Self.stepping(rig)
        rig.timer.fire()
        #expect(box.runs == 0, "the timer's pass waits for the next step's start")
        #expect(abs(try #require(rig.timer.armed) - 0.016) < 1e-6, "at most 16 ms")
        rig.clock.seconds += 0.005
        #expect(rig.pump.runIfDueAtStep() == " ran=1 deferred_ms=5.0")
        #expect(box.runs == 1)
        #expect(rig.pump.stats.stepDeferred == 1)
        #expect(abs(rig.pump.stats.stepDeferredMs - 5) < 1e-6)
        #expect(box.late.isEmpty)
    }

    @Test func requestsWhileAPassWaitsKeepItsBound() throws {
        let box = Box()
        let rig = Self.rig(box, onlyAtSteps: true)
        Self.stepping(rig)
        rig.timer.fire()
        rig.clock.seconds += 0.004
        rig.pump.request(milliseconds: 0)
        #expect(box.runs == 0)
        #expect(abs(try #require(rig.timer.armed) - 0.012) < 1e-6, "a new request does not wake the timer before the bound")
        #expect(rig.pump.stats.stepDeferred == 1, "one held pass")
    }

    @Test func aHeldPassRunsAtItsBoundWhenNoStepComes() {
        let box = Box()
        let rig = Self.rig(box, onlyAtSteps: true)
        Self.stepping(rig)
        rig.timer.fire()
        rig.clock.seconds += 0.016
        rig.timer.fire()
        #expect(box.runs == 1, "a paused pointer never starves the pages")
        #expect(rig.pump.stats.stepDeferTimeouts == 1)
        #expect(box.late == ["bound 16.0"])
    }

    @Test func theResizesEndRunsAHeldPassAtOnce() {
        let box = Box()
        let rig = Self.rig(box, onlyAtSteps: true)
        Self.stepping(rig)
        rig.timer.fire()
        rig.clock.seconds += 0.003
        rig.pump.resizeEnded()
        #expect(box.runs == 1)
        #expect(rig.pump.stats.stepDeferFlushes == 1)
        #expect(box.late == ["end 3.0"])
        rig.pump.resizeEnded()
        #expect(box.runs == 1, "once")
        rig.pump.request(milliseconds: 0)
        rig.timer.fire()
        #expect(box.runs == 2, "after the resize the timer runs at once")
    }

    @Test func afterAPauseInTheResizeTheTimerRunsAtOnce() {
        let box = Box()
        let rig = Self.rig(box, onlyAtSteps: true)
        Self.stepping(rig)
        rig.clock.seconds += 0.2
        rig.timer.fire()
        #expect(box.runs == 1, "no step for 100 ms: no live resize steps")
        #expect(rig.pump.stats.stepDeferred == 0)
    }

    @Test func withoutTheStepsKnobTheTimerNeverWaits() {
        let box = Box()
        let rig = Self.rig(box)
        Self.stepping(rig)
        rig.timer.fire()
        #expect(box.runs == 1)
        rig.pump.resizeEnded()
        #expect(box.runs == 1)
        #expect(rig.pump.stats.stepDeferred == 0)
    }
}
