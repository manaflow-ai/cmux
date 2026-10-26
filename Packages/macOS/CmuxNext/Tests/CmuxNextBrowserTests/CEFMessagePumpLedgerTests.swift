import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Every pump wake was one ledger reason, `scheduled`, so `debug.wakeups` could not tell a
/// Chromium delayed task from an immediate request, a kept cross-thread deadline or a nested
/// fire (plans/cmux-next/chrome-parity/p14-energy.md, task 018). Each fire now records why it
/// fired, and `earlyPasses` counts the delayed passes CEF answers with a request under 2 ms.
@MainActor
@Suite struct CEFMessagePumpLedgerTests {
    /// The pump's timer, fired by hand.
    final class Timer: CEFPumpTimer {
        var onFire: (() -> Void)?
        var armed: TimeInterval?
        func arm(after delay: TimeInterval, tolerance: TimeInterval) { armed = delay }
        func disarm() { armed = nil }
        func invalidate() { armed = nil }
        func fire() { armed = nil; onFire?() }
    }

    /// The pump's clock (uptime seconds), moved by hand.
    final class Clock {
        var seconds: TimeInterval = 100
        var nanos: UInt64 { UInt64(seconds * 1e9) }
    }

    /// A running pump whose start's immediate pass has run. `work` runs inside each pass.
    final class Rig {
        let timer = Timer()
        let clock = Clock()
        let ledger = WakeupLedger()
        let gate: CEFPumpCrossThreadGate
        var work: () -> Void = {}
        private(set) var pump: CEFMessagePump!

        init() {
            gate = CEFPumpCrossThreadGate(ledger: ledger)
            pump = CEFMessagePump(work: { [unowned self] in self.work() }, timer: timer, clock: { [clock] in clock.seconds },
                                  ledger: ledger, gate: gate)
            pump.start()
            timer.fire()
        }

        /// The ledger count of the pump's wakes for `reason`.
        func wakes(_ reason: CEFMessagePump.LedgerReason) -> UInt64 {
            ledger.snapshot().first { $0.owner == CEFMessagePump.ledgerOwner && $0.reason == reason.rawValue }?.count ?? 0
        }

        /// A CEF delayed request, then its fire date's pass.
        func delayedPass(milliseconds: Int64) {
            pump.request(milliseconds: milliseconds)
            clock.seconds += TimeInterval(milliseconds) / 1_000
            timer.fire()
        }
    }

    @Test func theReasonsAreNowDelayedKeptAndReentered() {
        #expect(CEFMessagePump.LedgerReason.allCases.map(\.rawValue) == ["now", "delayed", "kept", "reentered"])
    }

    @Test func aHundredMillisecondRequestFiresAsDelayed() {
        let rig = Rig()
        #expect(rig.wakes(.now) == 1, "the start's immediate pass")
        rig.delayedPass(milliseconds: 100)
        #expect(rig.wakes(.delayed) == 1)
        #expect(rig.wakes(.now) == 1)
        #expect(rig.ledger.snapshot().allSatisfy { $0.reason != "scheduled" }, "the old reason is gone")
    }

    @Test func aKeptCrossThreadDeadlineFiresAsKept() {
        let rig = Rig()
        rig.pump.request(milliseconds: 10)
        #expect(!rig.gate.admit(delayMilliseconds: 50, nowNanos: rig.clock.nanos), "kept: the armed +10 ms comes first")
        rig.clock.seconds += 0.010
        rig.timer.fire()
        #expect(rig.wakes(.delayed) == 1, "the +10 ms fire is CEF's own request")
        rig.clock.seconds += 0.040
        rig.timer.fire()
        #expect(rig.wakes(.kept) == 1, "the +50 ms fire is the kept deadline")
    }

    @Test func aFireInsideAPassIsReenteredAndCountersStayAsBefore() {
        let rig = Rig()
        var nested = true
        rig.work = {
            guard nested else { return }
            nested = false
            rig.timer.fire()
        }
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.wakes(.reentered) == 1)
        #expect(rig.pump.stats.reentrantFires == 1)
        #expect(rig.timer.armed == 0, "the outer pass runs the deferred fire on the next run loop pass")
        rig.timer.fire()
        let stats = rig.pump.stats
        #expect(stats.workRuns == 3, "start, the outer pass, the deferred one")
        #expect(stats.immediateRequests == 1)
        #expect(stats.delayedRequests == 0)
        #expect(stats.earlyPasses == 0)
    }

    /// CEF truncates a delay to whole milliseconds: the fire comes before Chromium's task is due and
    /// the pass ends with a re-ask that truncates to 0 or 1 ms, during the pass or just after it.
    @Test func aDelayedPassReaskedUnderTwoMillisecondsIsEarly() {
        let rig = Rig()
        rig.work = { rig.pump.request(milliseconds: 0) }
        rig.delayedPass(milliseconds: 7)
        #expect(rig.pump.stats.earlyPasses == 1, "re-asked for now inside the pass")
        rig.work = {}
        rig.timer.fire() // the re-ask's immediate pass
        rig.delayedPass(milliseconds: 7)
        rig.clock.seconds += 0.001
        rig.pump.request(milliseconds: 1)
        #expect(rig.pump.stats.earlyPasses == 2, "re-asked for 1 ms 1 ms after the pass")
        rig.pump.request(milliseconds: 1)
        #expect(rig.pump.stats.earlyPasses == 2, "one pass counts once")
    }

    @Test func otherPassesAndRequestsAreNotEarly() {
        let rig = Rig()
        rig.pump.scheduleNow()
        rig.timer.fire()
        rig.pump.request(milliseconds: 0)
        #expect(rig.pump.stats.earlyPasses == 0, "an immediate pass is no fire date")
        rig.timer.fire()
        rig.delayedPass(milliseconds: 7)
        rig.pump.request(milliseconds: 5)
        #expect(rig.pump.stats.earlyPasses == 0, "a re-ask of 2 ms or more is the next task")
        rig.delayedPass(milliseconds: 7)
        rig.clock.seconds += 0.003
        rig.pump.request(milliseconds: 1)
        #expect(rig.pump.stats.earlyPasses == 0, "3 ms after the pass is a new request")
        rig.timer.fire()
        rig.work = {
            rig.clock.seconds += CEFPumpSchedule.timeSlice + 0.001
            rig.pump.request(milliseconds: 0)
        }
        rig.delayedPass(milliseconds: 7)
        #expect(rig.pump.stats.earlyPasses == 0, "a pass that used the whole slice asks for now because work is left")
        #expect(rig.pump.stats.longWorkRuns == 1)
    }
}
