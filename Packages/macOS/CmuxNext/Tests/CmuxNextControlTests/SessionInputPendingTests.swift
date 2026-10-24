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
        events.dispatch(timestamp: 100, isKeyOrClick: true)
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

    /// With no input on its way, a check is one window-server query (the newest input of any
    /// type), not one per key and mouse-button type: the budget asks before every task.
    @Test func withNothingPendingACheckIsOneQuery() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        // Nothing recent.
        #expect(!input.hasPendingInput(uptime: 100))
        #expect(events.queries == 1)
        // The pointer moves and AppKit dispatches each move: still one query.
        events.ages[.mouseMoved] = 0.002
        events.dispatch(timestamp: 100 - 0.002, isKeyOrClick: false)
        #expect(!input.hasPendingInput(uptime: 100))
        #expect(events.queries == 2)
    }

    /// The one-query answer never hides a key: a key generated after the last dispatched event is
    /// found by the per-type queries, also while the pointer moves.
    @Test func aPendingKeyIsFoundWhileThePointerMoves() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        events.ages[.mouseMoved] = 0.006
        events.dispatch(timestamp: 100 - 0.006, isKeyOrClick: false)
        events.ages[.keyDown] = 0.003
        #expect(input.hasPendingInput(uptime: 100))
        #expect(events.queries == 2, "the any-input query, then key-down answered it")
        // A move AppKit has not dispatched yet, no key: the per-type queries say nothing is pending.
        events.dispatch(timestamp: 100 - 0.003, isKeyOrClick: true)
        events.ages[.mouseMoved] = 0.001
        #expect(!input.hasPendingInput(uptime: 100.0))
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
        events.dispatch(timestamp: 100.0, isKeyOrClick: true)
        now += 1_000_000  // past the budget's quarter-millisecond reuse of the last answer
        #expect(budget.mayRun(.automation), "dispatched: the batch runs")
        #expect(budget.stats.yieldedToInput[0] == 1 && budget.stats.yieldedToInput[1] == 1)
    }
}

/// The window server and AppKit as ``SessionInputPending`` sees them: event ages by type (the
/// any-input age is the youngest of them), whether the app is active, the dispatches a test
/// reports, and how many window-server queries a check made.
@MainActor
private final class FakeSessionEvents: SessionInputEvents {
    var ages: [CGEventType: TimeInterval] = [:]
    var isAppActive = true
    var canObserve = true
    private(set) var observeCalls = 0
    /// Window-server queries made (each is one synchronous call on the main thread in the app).
    private(set) var queries = 0
    private var dispatched: (@MainActor @Sendable (TimeInterval, Bool) -> Void)?

    func secondsSinceLastInput() -> TimeInterval {
        queries += 1
        return ages.values.min() ?? 10_000
    }

    func secondsSinceLastEvent(_ type: CGEventType) -> TimeInterval {
        queries += 1
        return ages[type] ?? 10_000
    }

    func observeDispatch(_ dispatched: @escaping @MainActor @Sendable (TimeInterval, Bool) -> Void) -> Bool {
        observeCalls += 1
        guard canObserve else { return false }
        self.dispatched = dispatched
        return true
    }

    /// AppKit dispatched an input event with `timestamp` (seconds since boot).
    func dispatch(timestamp: TimeInterval, isKeyOrClick: Bool) { dispatched?(timestamp, isKeyOrClick) }
}
