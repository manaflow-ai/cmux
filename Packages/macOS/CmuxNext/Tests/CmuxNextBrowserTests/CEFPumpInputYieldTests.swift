import CmuxNextInputCore
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextBrowser

/// The CEF pump's input policy (plans/cmux-next/chrome-parity/p04-input.md, task 024): a due pass
/// waits while a person's input for anything but a Chromium page is pending, until that input's
/// dispatch ends and one refresh at most in a row; after input to a Chromium page, a due pass runs at
/// once, because Chromium's input router and wheel acks run inside `CefDoMessageLoopWork`.
@MainActor
@Suite struct CEFPumpInputYieldTests {
    static let refresh: TimeInterval = 1.0 / 120

    @Test func noPendingInputRunsTheDuePassAsBefore() {
        let rig = Rig()
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 2, "the start's pass and the requested one")
        #expect(rig.pump.stats.deferredForInput == 0)
        #expect(rig.pump.stats.passesWhileInputPending == CEFPumpStats.PassesByTarget())
        #expect(rig.pump.stats.passTimes.count == 2)
    }

    @Test func pendingInputHoldsThePassUntilItsDispatchEnds() {
        let rig = Rig()
        rig.pending.isPending = true
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 1, "the key waits in the queue: no pass before it")
        #expect(rig.pump.stats.deferredForInput == 1)
        #expect(rig.timer.armed.map { abs($0 - Self.refresh) < 1e-9 } == true, "armed at the one-refresh bound")
        #expect(rig.timer.tolerance == 0)
        // The key is dispatched to a terminal: nothing pending, the held pass runs on the next run loop pass.
        rig.clock.advance(by: .milliseconds(2))
        rig.pending.isPending = false
        rig.dispatches.end(.other)
        #expect(rig.passes == 1, "never inside another target's dispatch")
        #expect(rig.timer.armed == 0)
        rig.timer.fire()
        #expect(rig.passes == 2)
        #expect(rig.pump.stats.passesWhileInputPending.other == 0, "DC2: no pass while non-Chromium input was pending")
        #expect(rig.pump.stats.deferredForInput == 1)
    }

    /// The one-refresh bound holds across a stream of input: a later dispatch does not start the
    /// wait over, so the pass runs at the first hold's deadline (the frame deadline as fallback).
    @Test func aPassWaitsAtMostOneRefreshInARow() {
        let rig = Rig()
        rig.pending.isPending = true
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 1)
        rig.clock.advance(by: .milliseconds(5))
        rig.dispatches.end(.other) // the next key is already queued
        rig.timer.fire()
        #expect(rig.passes == 1, "still within the refresh")
        #expect(rig.timer.armed.map { abs($0 - (Self.refresh - 0.005)) < 1e-9 } == true, "the first hold's deadline, not a new one")
        rig.clock.advance(by: .nanoseconds(Int64(Self.refresh * 1e9) - 5_000_000))
        rig.timer.fire()
        #expect(rig.passes == 2, "one refresh in a row at most")
        #expect(rig.pump.stats.passesWhileInputPending.other == 1)
        #expect(rig.pump.stats.deferredForInput == 1, "one hold, however many fires it took")
        // The bound starts over after a pass.
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 2)
        #expect(rig.pump.stats.deferredForInput == 2)
    }

    @Test func inputToAChromiumPageRunsOnePassAtOnceAfterItsDispatch() {
        let rig = Rig()
        rig.pending.isPending = true
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 1)
        // The wheel event reaches the page; Chromium asks for work to route and ack it.
        rig.pump.request(milliseconds: 0)
        rig.dispatches.end(.chromiumPage)
        #expect(rig.passes == 2, "the pass runs inside the dispatch's end, not a run loop pass later")
        #expect(rig.pump.stats.passesWhileInputPending.chromiumPage == 1, "the next wheel is already queued")
        #expect(rig.pump.stats.passesWhileInputPending.other == 0)
    }

    @Test func aChromiumDispatchWithNoDueWorkRunsNoPass() {
        let rig = Rig()
        rig.pump.request(milliseconds: 50)
        rig.dispatches.end(.chromiumPage)
        #expect(rig.passes == 1, "only the start's pass: CEF's delayed task is not due")
        #expect(rig.timer.armed.map { abs($0 - 0.05) < 1e-9 } == true)
    }

    /// A dispatch that ends inside a pass (a nested run loop: a menu, a modal panel) runs nothing;
    /// the outer pass re-arms when it returns, as the reentrancy rule says.
    @Test func aDispatchInsideAPassDoesNotReenterThePump() {
        let rig = Rig()
        var depth = 0
        var maxDepth = 0
        rig.onWork = {
            depth += 1
            maxDepth = max(maxDepth, depth)
            rig.pump.scheduleNow()
            rig.dispatches.end(.chromiumPage)
            depth -= 1
        }
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(maxDepth == 1)
        #expect(rig.passes == 2)
        #expect(rig.timer.armed == 0, "the request made inside the pass runs on the next run loop pass")
    }

    @Test func stopEndsTheDispatchSubscription() {
        let rig = Rig()
        rig.pump.stop()
        #expect(rig.dispatches.isCancelled)
        rig.pump.request(milliseconds: 0)
        rig.dispatches.end(.chromiumPage)
        #expect(rig.passes == 1)
    }

    /// Without a policy (the feature off) pending input changes nothing.
    @Test func withoutAPolicyInputHoldsNothing() {
        let clock = ManualClock()
        let timer = Timer()
        var passes = 0
        let pump = CEFMessagePump(work: { passes += 1 }, safetyNet: .none, timer: timer, clock: { clock.seconds },
                                  ledger: WakeupLedger())
        pump.start()
        timer.fire()
        pump.scheduleNow()
        timer.fire()
        #expect(passes == 2)
        #expect(pump.stats.passTimes.count == 0)
        pump.stop()
    }

    // MARK: Doubles

    @MainActor
    final class Rig {
        let clock = ManualClock()
        let timer = Timer()
        let pending = Pending()
        let dispatches = Dispatches()
        var passes = 0
        var onWork: () -> Void = {}
        private(set) var pump: CEFMessagePump!

        init() {
            let clock = clock
            pump = CEFMessagePump(work: { [unowned self] in
                self.passes += 1
                self.onWork()
            }, safetyNet: .none, timer: timer, clock: { clock.seconds }, ledger: WakeupLedger())
            pump.setInputPolicy(CEFPumpInputPolicy(pending: pending, dispatches: dispatches,
                                                   refreshInterval: { CEFPumpInputYieldTests.refresh }))
            pump.start()
            timer.fire()
        }
    }

    final class Pending: InputPendingSource {
        var isPending = false
        func hasPendingInput(uptime: TimeInterval) -> Bool { isPending }
    }

    final class Dispatches: CEFPumpInputDispatches {
        private var handler: ((CEFPumpInputPolicy.Target) -> Void)?
        private var subscription: InputSubscription?

        var isCancelled: Bool { subscription?.isCancelled ?? true }

        func observeDispatchEnd(_ handler: @escaping (CEFPumpInputPolicy.Target) -> Void) -> InputSubscription {
            self.handler = handler
            let subscription = InputSubscription(flag: InputSubscriptionFlag())
            self.subscription = subscription
            return subscription
        }

        func end(_ target: CEFPumpInputPolicy.Target) {
            guard !isCancelled else { return }
            handler?(target)
        }
    }

    /// The pump's timer, fired by hand.
    final class Timer: CEFPumpTimer {
        var onFire: (() -> Void)?
        var armed: TimeInterval?
        var tolerance: TimeInterval?
        func arm(after delay: TimeInterval, tolerance: TimeInterval) {
            armed = delay
            self.tolerance = tolerance
        }
        func disarm() { armed = nil }
        func invalidate() { armed = nil }
        func fire() {
            armed = nil
            onFire?()
        }
    }
}

private extension ManualClock {
    /// The clock's time in seconds, the pump's clock unit.
    nonisolated var seconds: TimeInterval {
        let offset = now.offset.components
        return 100 + TimeInterval(offset.seconds) + TimeInterval(offset.attoseconds) / 1e18
    }
}
