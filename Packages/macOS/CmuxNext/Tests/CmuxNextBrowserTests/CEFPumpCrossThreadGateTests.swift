import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextBrowser

/// A CEF `OnScheduleMessagePumpWork` from a Chromium thread posted a block to the main run loop and
/// woke it every time, also for a delayed request whose deadline came after the pump's armed fire
/// (an idle app with a Chromium page: main wakes outside the wakeup ledger). The gate drops only
/// those, and never a request the running or next pass would miss.
@MainActor
@Suite struct CEFPumpCrossThreadGateTests {
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
    }

    /// A pump at uptime 100 s whose timer is armed for a CEF request 10 ms out.
    static func armedPump(work: @escaping () -> Void = {}, ledger: WakeupLedger = WakeupLedger(), clock: Clock = Clock())
        -> (CEFMessagePump, Timer, CEFPumpCrossThreadGate, now: () -> UInt64) {
        let timer = Timer()
        let gate = CEFPumpCrossThreadGate(ledger: ledger)
        let pump = CEFMessagePump(work: work, safetyNet: .none, timer: timer, clock: { clock.seconds }, ledger: ledger, gate: gate)
        pump.start()
        timer.fire() // the start's immediate pass
        pump.request(milliseconds: 10)
        return (pump, timer, gate, { UInt64(clock.seconds * 1e9) })
    }

    @Test func aDelayedRequestAfterTheArmedFireWakesNothing() {
        let ledger = WakeupLedger()
        let (pump, _, gate, now) = Self.armedPump(ledger: ledger)
        #expect(!gate.admit(delayMilliseconds: 50, nowNanos: now()), "the armed fire at +10 ms comes first")
        #expect(!gate.admit(delayMilliseconds: 10, nowNanos: now()), "the same deadline is covered")
        #expect(gate.dropped == 2)
        #expect(pump.stats.droppedCrossThreadRequests == 2)
        #expect(!ledger.snapshot().contains { $0.reason == "cross-thread request" }, "a dropped request is no wake")
    }

    @Test func everyOtherRequestGoesThroughAndCountsAsAWake() {
        let ledger = WakeupLedger()
        let (_, _, gate, now) = Self.armedPump(ledger: ledger)
        #expect(gate.admit(delayMilliseconds: 5, nowNanos: now()), "earlier than the armed fire")
        #expect(gate.admit(delayMilliseconds: 0, nowNanos: now()), "immediate")
        #expect(gate.admit(delayMilliseconds: 50, nowNanos: now() + 20_000_000), "the armed fire is already due")
        #expect(gate.dropped == 0)
        #expect(ledger.snapshot().first { $0.reason == "cross-thread request" }?.count == 3)
    }

    /// The race the rule closes: a request that arrives while `CefDoMessageLoopWork` runs (the
    /// published deadline would be the one that just fired) always reaches the main thread.
    @Test func aDelayedRequestDuringThePassIsNeverLost() {
        var admittedDuringWork: Bool?
        var gateBox: CEFPumpCrossThreadGate?
        let clock = Clock()
        let (_, timer, gate, now) = Self.armedPump(work: {
            admittedDuringWork = gateBox?.admit(delayMilliseconds: 50, nowNanos: UInt64(clock.seconds * 1e9))
        }, clock: clock)
        gateBox = gate
        clock.seconds = 100.010
        timer.fire() // the armed +10 ms pass runs; a Chromium thread asks during its work
        #expect(admittedDuringWork == true, "a request during the pass was dropped")
        #expect(gate.admit(delayMilliseconds: 50, nowNanos: now()), "nothing is armed after the pass: it goes through")
    }

    @Test func aStoppedPumpDropsNothing() {
        let (pump, _, gate, now) = Self.armedPump()
        pump.stop()
        #expect(gate.admit(delayMilliseconds: 50, nowNanos: now()))
    }
}
