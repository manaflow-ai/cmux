import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextBrowser

/// `CMUX_NEXT_CEF_PUMP_AT_STEP=1`: a window live resize keeps the main thread in cmux's steps, and the pump's timer got
/// about 10 passes a second (window corner drags, Chromium trace: bursts of browser-main tasks every 91 ms p50, against
/// every 8.3 ms in a divider drag), so each page's ack of its new size waited and its next size waited in Chromium's
/// resize IPC throttle. The pump also runs at each step's start the work CEF already asked for: a request whose
/// deadline passed, or an immediate one still on its way from a Chromium thread; never re-entrantly, never work CEF
/// did not ask for.
@MainActor
@Suite struct CEFPumpAtStepTests {
    typealias Timer = CEFPumpCrossThreadGateTests.Timer
    typealias Clock = CEFPumpCrossThreadGateTests.Clock

    final class Box {
        var runs = 0
        var pump: CEFMessagePump?
        var inner: [Bool] = []
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
        #expect(rig.pump.runIfDueAtStep())
        #expect(box.runs == 1)
        #expect(!rig.pump.runIfDueAtStep(), "nothing is due after the pass")
        #expect(box.runs == 1)
        #expect(rig.pump.stats.stepRuns == 1)
        #expect(rig.pump.stats.stepNotDue == 1)
    }

    @Test func aDelayedRequestRunsOnlyOnceItsDeadlinePassed() {
        let box = Box()
        let rig = Self.rig(box)
        rig.pump.request(milliseconds: 10)
        #expect(!rig.pump.runIfDueAtStep(), "CEF asked for work in 10 ms, not now")
        #expect(box.runs == 0)
        rig.clock.seconds += 0.011
        #expect(rig.pump.runIfDueAtStep())
        #expect(box.runs == 1)
    }

    @Test func anImmediateRequestOnItsWayFromAChromiumThreadIsDue() {
        let box = Box()
        let rig = Self.rig(box)
        rig.gate.immediatePosted()  // posted to the main run loop, its block not run yet
        #expect(rig.pump.runIfDueAtStep())
        #expect(box.runs == 1)
        #expect(rig.pump.stats.stepRunsInFlight == 1)
        rig.gate.immediateDelivered()
        #expect(!rig.pump.runIfDueAtStep())
    }

    @Test func aStepInsideAPassRunsNothing() {
        let box = Box()
        let rig = Self.rig(box) { box.inner.append(box.pump?.runIfDueAtStep() ?? true) }
        let skipped = rig.pump.stats.stepSkippedInPass
        rig.pump.request(milliseconds: 0)
        rig.timer.fire()
        #expect(box.runs == 1)
        #expect(box.inner == [false], "a step begun from a CEF callback inside the pass runs no pass of its own")
        #expect(rig.pump.stats.stepSkippedInPass == skipped + 1)
    }

    @Test func aStoppedPumpRunsNothing() {
        let box = Box()
        let rig = Self.rig(box)
        rig.pump.request(milliseconds: 0)
        rig.pump.stop()
        #expect(!rig.pump.runIfDueAtStep())
        #expect(box.runs == 0)
    }
}
