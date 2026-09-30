import Foundation
import Testing
@testable import CmuxNextBrowser
import CmuxNextWakeups

/// Stands in for the run loop timer: records the armed delay and fires on
/// demand, the way the run loop would once that delay passes.
private final class FakePumpTimer: CEFPumpTimer {
    var onFire: (() -> Void)?
    /// Seconds until the pending fire; nil while disarmed.
    private(set) var delay: TimeInterval?
    private(set) var tolerance: TimeInterval = 0
    private(set) var invalidated = false

    func arm(after delay: TimeInterval, tolerance: TimeInterval) {
        self.delay = delay
        self.tolerance = tolerance
    }

    func disarm() { delay = nil }

    func invalidate() {
        invalidated = true
        delay = nil
        onFire = nil
    }

    /// A one-shot fire: the timer is disarmed again before its handler runs.
    func fire() {
        delay = nil
        onFire?()
    }
}

private final class PumpHarness {
    let timer = FakePumpTimer()
    var now: TimeInterval = 100
    var works = 0
    /// Runs inside the fake `CefDoMessageLoopWork`.
    var onWork: (() -> Void)?
    private(set) lazy var pump = CEFMessagePump(
        work: { [unowned self] in
            works += 1
            onWork?()
        },
        timer: timer,
        clock: { [unowned self] in now }
    )

    /// Starts the pump and runs its first pass, so later arms are the
    /// pump's own decisions.
    func started() -> PumpHarness {
        pump.start()
        timer.fire()
        return self
    }

    /// Lets the pending timer fire when its delay passes; returns that delay.
    @discardableResult
    func advanceToFire() -> TimeInterval? {
        guard let delay = timer.delay else { return nil }
        now += delay
        timer.fire()
        return delay
    }
}

private func close(_ value: TimeInterval?, _ expected: TimeInterval) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < 1e-9
}

@Suite struct CEFMessagePumpTests {
    @Test func nothingIsArmedBeforeStart() {
        let harness = PumpHarness()
        harness.pump.request(milliseconds: 0)
        #expect(harness.timer.delay == nil)
        harness.pump.start()
        #expect(harness.timer.delay == 0)
        harness.timer.fire()
        #expect(harness.works == 1)
    }

    @Test func immediateRequestRunsOnTheNextRunLoopPass() {
        let harness = PumpHarness().started()
        harness.pump.request(milliseconds: 0)
        #expect(harness.timer.delay == 0)
        #expect(harness.timer.tolerance == 0)
    }

    @Test func delayedRequestWaitsExactlyThatLong() {
        let harness = PumpHarness().started()
        harness.pump.request(milliseconds: 250)
        #expect(close(harness.timer.delay, 0.25))
        #expect(harness.timer.tolerance == 0)
        harness.pump.request(milliseconds: 5_000)
        #expect(close(harness.timer.delay, 5))
    }

    @Test func newerDelayedRequestReplacesTheTimer() {
        let harness = PumpHarness().started()
        harness.pump.request(milliseconds: 900)
        harness.pump.request(milliseconds: 250)
        #expect(close(harness.timer.delay, 0.25))
        // CEF always reports its earliest delayed task, so a later request
        // replaces an earlier one.
        harness.pump.request(milliseconds: 900)
        #expect(close(harness.timer.delay, 0.9))
        harness.advanceToFire()
        #expect(harness.works == 2)
    }

    @Test func delayedRequestNeverPostponesPendingImmediateWork() {
        let harness = PumpHarness().started()
        harness.pump.request(milliseconds: 0)
        harness.pump.request(milliseconds: 500)
        #expect(harness.timer.delay == 0)
    }

    @Test func stopCancelsTheTimerAndNoWorkRunsAfter() {
        let harness = PumpHarness().started()
        harness.pump.request(milliseconds: 0)
        harness.pump.stop()
        #expect(harness.timer.invalidated)
        harness.pump.request(milliseconds: 0)
        #expect(harness.timer.delay == nil)
        // After stop, CefShutdown may already have run: CEF must not pump.
        harness.pump.pumpNow()
        #expect(harness.works == 1)
    }

    @Test func reentrantFireIsDeferredUntilTheOuterPassEnds() {
        let harness = PumpHarness().started()
        harness.onWork = { [unowned harness] in
            // A nested run loop (menu, modal panel) fires the timer inside
            // CefDoMessageLoopWork.
            if harness.works == 2 { harness.pump.pumpNow() }
        }
        harness.pump.request(milliseconds: 0)
        harness.timer.fire()
        #expect(harness.works == 2)
        #expect(harness.pump.stats.reentrantFires == 1)
        // The deferred work runs right after the outer pass.
        #expect(harness.timer.delay == 0)
        harness.timer.fire()
        #expect(harness.works == 3)
    }

    @Test func requestDuringWorkArmsNothingUntilTheWorkReturns() {
        let harness = PumpHarness().started()
        var delayDuringWork: TimeInterval? = -1
        harness.onWork = { [unowned harness] in
            harness.pump.request(milliseconds: 0)
            delayDuringWork = harness.timer.delay
        }
        harness.pump.request(milliseconds: 0)
        harness.timer.fire()
        // A nested run loop inside the work must not spin on the timer.
        #expect(delayDuringWork == nil)
        #expect(harness.timer.delay == 0)
    }

    @Test func workThatUsesCEFsWholeTimeSliceRunsAgainAtOnce() {
        let harness = PumpHarness().started()
        harness.onWork = { [unowned harness] in harness.now += 0.012 }
        harness.pump.request(milliseconds: 0)
        harness.timer.fire()
        // CEF stops after 10 ms with work left and does not ask again.
        #expect(harness.timer.delay == 0)
        #expect(harness.pump.stats.longWorkRuns == 1)
    }

    @Test func followUpWakesBackOffAndThenThePumpSleeps() {
        let harness = PumpHarness().started()
        var delays: [TimeInterval] = []
        for _ in 0..<10 {
            guard let delay = harness.advanceToFire() else { break }
            delays.append(delay)
        }
        // CEF does not report delayed work a pass posted: a few follow-ups
        // catch it, then nothing wakes until CEF asks.
        let expected: [TimeInterval] = [1.0 / 30, 2.0 / 30, 4.0 / 30, 8.0 / 30, 16.0 / 30, 1]
        #expect(delays.count == expected.count, "\(delays)")
        for (delay, value) in zip(delays, expected) {
            #expect(close(delay, value), "\(delays)")
        }
        #expect(harness.timer.delay == nil)
        #expect(harness.pump.stats.followUpRuns == expected.count)
    }

    @Test func followUpWakesMayCoalesce() {
        let harness = PumpHarness().started()
        #expect(close(harness.timer.delay, 1.0 / 30))
        #expect(harness.timer.tolerance > 0)
    }

    @Test func anyRequestStartsTheFollowUpsAgain() {
        let harness = PumpHarness().started()
        for _ in 0..<20 where harness.advanceToFire() != nil {}
        #expect(harness.timer.delay == nil)
        harness.pump.request(milliseconds: 0)
        harness.timer.fire()
        #expect(close(harness.timer.delay, 1.0 / 30))
    }

    @Test func idleMinuteWakesAtMostSixTimes() {
        let harness = PumpHarness().started()
        let end = harness.now + 60
        var wakeups = 0
        while harness.now < end, harness.advanceToFire() != nil { wakeups += 1 }
        #expect(wakeups <= 6, "\(wakeups) wakeups in an idle minute")
    }

    @Test func timerWakeupsGoToTheLedger() {
        let ledger = WakeupLedger()
        let timer = FakePumpTimer()
        var now: TimeInterval = 100
        let pump = CEFMessagePump(work: {}, timer: timer, clock: { now }, ledger: ledger)
        pump.start()
        timer.fire()
        now += 1.0 / 30
        timer.fire()
        let reasons = Dictionary(uniqueKeysWithValues: ledger.snapshot()
            .filter { $0.owner == "CEFMessagePump" }.map { ($0.reason, $0.count) })
        #expect(reasons == ["scheduled": 1, "fallback": 1])
    }
}
