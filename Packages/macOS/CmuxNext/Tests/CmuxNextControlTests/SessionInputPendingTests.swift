import CmuxNextWakeups
import CoreGraphics
import Foundation
import Testing

/// The production pending-input detector (``SessionInputPending``) that makes budgeted batches
/// yield to a person's key or click: the path a real key takes (window server, event queue, AppKit
/// dispatch), which `debug.key` never exercises. Driven through its window-server seam.
@MainActor @Suite struct SessionInputPendingTests {
    @Test func aKeyTheWindowServerGeneratedAndAppKitHasNotDispatchedIsPending() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        events.ages[.keyDown] = 0.004
        #expect(input.hasPendingInput(uptime: 100))
        // AppKit dispatched it (the local monitor saw an event at least that new).
        events.dispatch(timestamp: 100)
        #expect(!input.hasPendingInput(uptime: 100.001))
    }

    @Test func aClickCountsAndAMouseMoveDoesNot() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        events.ages[.mouseMoved] = 0.002
        #expect(!input.hasPendingInput(uptime: 50), "pointer motion streams: it must not hold batches")
        events.ages[.leftMouseDown] = 0.002
        #expect(input.hasPendingInput(uptime: 50))
    }

    @Test func anEventTheAppNeverDispatchesStopsCountingAfterTwoFrames() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        events.ages[.keyDown] = SessionInputPending.staleAfter + 0.005
        #expect(!input.hasPendingInput(uptime: 100))
    }

    @Test func anInactiveAppHasNoPendingInput() {
        let events = FakeSessionEvents()
        events.isAppActive = false
        let input = SessionInputPending(events: events)
        events.ages[.keyDown] = 0.002
        #expect(!input.hasPendingInput(uptime: 100), "the session's key belongs to the active app")
    }

    @Test func itStartsWatchingDispatchOnceThereIsAnApp() {
        let events = FakeSessionEvents()
        events.canObserve = false
        let input = SessionInputPending(events: events)
        events.ages[.keyDown] = 0.002
        _ = input.hasPendingInput(uptime: 100)
        #expect(events.observeCalls == 1)
        events.canObserve = true
        _ = input.hasPendingInput(uptime: 100)
        _ = input.hasPendingInput(uptime: 100)
        #expect(events.observeCalls == 2, "asked again until it could, then never again")
    }

    /// The whole chain a real key takes into the scheduler: a key the window server holds for the
    /// app makes every budgeted class yield; once AppKit dispatched it, the batch runs.
    @Test func aPendingRealKeyMakesTheBudgetYieldUntilItIsDispatched() {
        let events = FakeSessionEvents()
        var now: UInt64 = 100_000_000_000
        let budget = MainFrameBudget(input: SessionInputPending(events: events), uptimeNanos: { now })
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        events.ages[.keyDown] = 0.003
        #expect(!budget.mayRun(.visible), "a key on its way through the event queue goes before the batch")
        #expect(!budget.mayRun(.automation))
        #expect(budget.mayRun(.frame))
        events.dispatch(timestamp: 100.0)
        now += 1_000_000  // past the budget's quarter-millisecond reuse of the last answer
        #expect(budget.mayRun(.automation), "dispatched: the batch runs")
        #expect(budget.stats.yieldedToInput[0] == 1 && budget.stats.yieldedToInput[1] == 1)
    }
}

/// The window server and AppKit as ``SessionInputPending`` sees them: event ages by type, whether
/// the app is active, and the dispatches a test reports.
@MainActor
private final class FakeSessionEvents: SessionInputEvents {
    var ages: [CGEventType: TimeInterval] = [:]
    var isAppActive = true
    var canObserve = true
    private(set) var observeCalls = 0
    private var dispatched: (@MainActor @Sendable (TimeInterval) -> Void)?

    func secondsSinceLastEvent(_ type: CGEventType) -> TimeInterval { ages[type] ?? 10_000 }

    func observeDispatch(_ dispatched: @escaping @MainActor @Sendable (TimeInterval) -> Void) -> Bool {
        observeCalls += 1
        guard canObserve else { return false }
        self.dispatched = dispatched
        return true
    }

    /// AppKit dispatched an event with `timestamp` (seconds since boot).
    func dispatch(timestamp: TimeInterval) { dispatched?(timestamp) }
}
