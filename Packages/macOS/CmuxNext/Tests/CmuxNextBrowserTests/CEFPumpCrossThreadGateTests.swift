import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextBrowser

/// A CEF `OnScheduleMessagePumpWork` from a Chromium thread posted a block to the main run loop and
/// woke it every time, also for a delayed request whose deadline came after the pump's armed fire
/// (an idle app with a Chromium page: main wakes outside the wakeup ledger). The gate keeps those
/// with no wake, and the main thread merges them at its next pass or re-arm: none is ever lost.
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
        var nanos: UInt64 { UInt64(seconds * 1e9) }
    }

    /// A running pump (held by the caller: its timer holds it weakly) whose timer is armed for a
    /// CEF request 10 ms out, at uptime 100 s.
    struct Rig {
        let pump: CEFMessagePump
        let timer: Timer
        let gate: CEFPumpCrossThreadGate
        let clock: Clock
        let ledger: WakeupLedger
    }

    static func rig(safetyNet: CEFPumpSchedule.SafetyNet = .none, work: @escaping () -> Void = {}) -> Rig {
        let timer = Timer()
        let clock = Clock()
        let ledger = WakeupLedger()
        let gate = CEFPumpCrossThreadGate(ledger: ledger)
        let pump = CEFMessagePump(work: work, safetyNet: safetyNet, timer: timer, clock: { clock.seconds }, ledger: ledger, gate: gate)
        pump.start()
        timer.fire() // the start's immediate pass
        pump.request(milliseconds: 10)
        return Rig(pump: pump, timer: timer, gate: gate, clock: clock, ledger: ledger)
    }

    static func crossThreadWakes(_ ledger: WakeupLedger) -> UInt64 {
        ledger.snapshot().first { $0.owner == "CEFMessagePump" && $0.reason == "cross-thread request" }?.count ?? 0
    }

    @Test func aDelayedRequestAfterTheArmedFireWakesNothing() {
        let rig = Self.rig()
        #expect(!rig.gate.admit(delayMilliseconds: 50, nowNanos: rig.clock.nanos), "the armed fire at +10 ms comes first")
        #expect(!rig.gate.admit(delayMilliseconds: 10, nowNanos: rig.clock.nanos), "the same deadline is covered")
        #expect(rig.pump.stats.keptCrossThreadRequests == 2)
        #expect(Self.crossThreadWakes(rig.ledger) == 0, "a kept request is no wake")
    }

    @Test func everyOtherRequestGoesThroughAndCountsAsAWake() {
        let rig = Self.rig()
        #expect(rig.gate.admit(delayMilliseconds: 5, nowNanos: rig.clock.nanos), "earlier than the armed fire")
        #expect(rig.gate.admit(delayMilliseconds: 0, nowNanos: rig.clock.nanos), "immediate")
        #expect(rig.gate.admit(delayMilliseconds: 50, nowNanos: rig.clock.nanos + 20_000_000), "the armed fire is already due")
        #expect(rig.gate.kept == 0)
        #expect(Self.crossThreadWakes(rig.ledger) == 3)
    }

    /// A kept request still runs when the armed pass reports nothing new (CEF need not report it
    /// again): after the +10 ms pass the timer is armed for the kept +50 ms.
    @Test func aKeptRequestIsArmedAfterThePass() {
        let rig = Self.rig()
        #expect(!rig.gate.admit(delayMilliseconds: 50, nowNanos: rig.clock.nanos))
        rig.clock.seconds = 100.010
        rig.timer.fire()
        let armed = rig.timer.armed
        #expect(armed.map { abs($0 - 0.040) < 0.000_5 } == true, "the kept +50 ms request was lost (armed \(String(describing: armed)))")
    }

    /// The reviewer's race: a block posted before the keep (T1's 500 ms request) runs after it and
    /// moves the armed fire later. The kept request still bounds it.
    @Test func aStaleLaterRequestCannotStrandAKeptOne() {
        let rig = Self.rig()
        #expect(!rig.gate.admit(delayMilliseconds: 50, nowNanos: rig.clock.nanos))
        rig.pump.request(milliseconds: 500) // the stale main-thread block
        #expect(rig.timer.armed.map { $0 <= 0.050 + 0.000_5 } == true, "armed at \(String(describing: rig.timer.armed)), after the kept +50 ms")
    }

    /// A request made while the pass's work runs (the timer just fired) is never kept.
    @Test func aDelayedRequestDuringThePassGoesThrough() {
        var admittedDuringWork: Bool?
        var probe: (() -> Bool)?
        let rig = Self.rig(work: { admittedDuringWork = probe?() })
        probe = { rig.gate.admit(delayMilliseconds: 50, nowNanos: rig.clock.nanos) }
        rig.clock.seconds = 100.010
        rig.timer.fire()
        #expect(admittedDuringWork == true, "a request during the pass was kept against a fire that already ran")
    }

    /// An older fork (a safety-net pump) does not report its next task after each pass: the gate
    /// keeps nothing there.
    @Test func anOldForkKeepsNothing() {
        let rig = Self.rig(safetyNet: .followUps(first: 1.0 / 30, last: 1))
        #expect(rig.gate.admit(delayMilliseconds: 50, nowNanos: rig.clock.nanos))
        #expect(rig.gate.kept == 0)
    }

    @Test func aStoppedPumpKeepsNothing() {
        let rig = Self.rig()
        rig.pump.stop()
        #expect(rig.gate.admit(delayMilliseconds: 50, nowNanos: rig.clock.nanos))
    }
}
