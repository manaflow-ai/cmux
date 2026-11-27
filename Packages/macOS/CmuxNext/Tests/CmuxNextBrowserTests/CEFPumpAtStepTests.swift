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
    }

    struct Rig {
        let pump: CEFMessagePump
        let timer: Timer
        let clock: Clock
        let gate: CEFPumpCrossThreadGate
    }

    /// A running demand-driven pump (no safety net) after its start's pass, its work counted in `box`.
    static func rig(_ box: Box, work: @escaping () -> Void = {}) -> Rig {
        let timer = Timer()
        let clock = Clock()
        let gate = CEFPumpCrossThreadGate(ledger: WakeupLedger())
        let pump = CEFMessagePump(work: { box.runs += 1; work() }, safetyNet: .none, timer: timer, clock: { clock.seconds },
                                  ledger: WakeupLedger(), gate: gate)
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

    // The pass at each step's start adds a pass; it never holds one back (the coordinator, 2026-11-27). Its steps-only
    // form (`CMUX_NEXT_CEF_PUMP_AT_STEP=steps`) held a due timer pass for the next step's start, up to 16 ms, and the
    // divider drag's acks waited longer for it: R - P 6.8 ms p50 without the lever, 10.9 ms with it (psr2b and psr3,
    // Chromium traces). `steps` now means what `1` does: a due timer pass with no step running runs at once.

    /// A live resize: a step began, and CEF asked for work now 2 ms later (the clock at 100.002 s).
    static func stepping(_ rig: Rig) {
        #expect(rig.pump.runIfDueAtStep() == nil, "the step's start: nothing is due yet")
        rig.clock.seconds += 0.002
        rig.pump.request(milliseconds: 0)
    }

    @Test func inALiveResizeADueTimerPassRunsAtOnce() {
        let box = Box()
        let rig = Self.rig(box)
        Self.stepping(rig)
        rig.timer.fire()
        #expect(box.runs == 1, "no step runs, the pass is due: it runs now, not at the next step's start")
        #expect(rig.pump.runIfDueAtStep() == nil, "the next step finds nothing left to do")
        #expect(box.runs == 1)
    }

    @Test func aRequestInALiveResizeArmsTheTimerAtItsOwnDeadline() throws {
        let box = Box()
        let rig = Self.rig(box)
        Self.stepping(rig)
        #expect(try #require(rig.timer.armed) < 1e-6, "work for now: the timer is armed for now, not for a step's bound")
        rig.timer.fire()
        rig.pump.request(milliseconds: 5)
        #expect(abs(try #require(rig.timer.armed) - 0.005) < 1e-6, "a delayed request keeps its 5 ms")
    }

    @Test func theStepsPassAddsToTheTimersPasses() {
        let box = Box()
        let rig = Self.rig(box)
        Self.stepping(rig)
        #expect(rig.pump.runIfDueAtStep() == " ran=1", "the next step's start runs the due work")
        #expect(box.runs == 1)
        rig.clock.seconds += 0.003
        rig.pump.request(milliseconds: 0)
        rig.timer.fire()
        #expect(box.runs == 2, "and the timer still runs the work asked for after it")
    }
}
