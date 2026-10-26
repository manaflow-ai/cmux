import AppKit
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
        events.dispatch(timestamp: 100, .keyOrClick)
        #expect(!input.hasPendingInput(uptime: 100.001))
    }

    @Test func aClickCountsAndAMouseMoveDoesNot() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        events.ages[.mouseMoved] = 0.002
        #expect(!input.hasPendingInput(uptime: 50), "pointer motion streams: it must not hold batches")
        events.ages[.leftMouseDown] = 0.002
        #expect(input.hasPendingInput(uptime: 50))
        events.dispatch(timestamp: 50, .leftMouseDown)
        #expect(!input.hasPendingInput(uptime: 50.001), "a dispatched left mouse-down is a dispatched click")
    }

    @Test func anEventTheAppNeverDispatchesStopsCountingAfterTwoFrames() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        events.ages[.keyDown] = input.staleAfter + 0.005
        #expect(!input.hasPendingInput(uptime: 100))
    }

    @Test func anInactiveAppHasNoPendingInput() {
        let events = FakeSessionEvents()
        events.isAppActive = false
        let input = SessionInputPending(events: events)
        events.ages[.keyDown] = 0.002
        #expect(!input.hasPendingInput(uptime: 100), "the session's key belongs to the active app")
    }

    @Test func itWatchesDispatchOnceFromItsInit() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        #expect(events.observeCalls == 1, "watching starts before the first check")
        events.ages[.keyDown] = 0.002
        _ = input.hasPendingInput(uptime: 100)
        _ = input.hasPendingInput(uptime: 100)
        #expect(events.observeCalls == 1, "checks never ask again")
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
        events.dispatch(timestamp: 100 - 0.002, .other)
        #expect(!input.hasPendingInput(uptime: 100))
        #expect(events.queries == 2)
    }

    /// The one-query answer never hides a key: a key generated after the last dispatched event is
    /// found by the per-type queries, also while the pointer moves.
    @Test func aPendingKeyIsFoundWhileThePointerMoves() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        events.ages[.mouseMoved] = 0.006
        events.dispatch(timestamp: 100 - 0.006, .other)
        events.ages[.keyDown] = 0.003
        #expect(input.hasPendingInput(uptime: 100))
        #expect(events.queries == 2, "the any-input query, then key-down answered it")
        // A move AppKit has not dispatched yet, no key: the per-type queries say nothing is pending.
        events.dispatch(timestamp: 100 - 0.003, .keyOrClick)
        events.ages[.mouseMoved] = 0.001
        #expect(!input.hasPendingInput(uptime: 100.0))
    }

    // MARK: Scrolls

    /// A scroll that begins a gesture is pending (Chrome holds the first wheel of a sequence); a
    /// tick in the middle of one is not.
    @Test func aScrollBeginIsPendingAndAMidGestureTickIsNot() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        events.ages[.scrollWheel] = 0.003
        #expect(input.hasPendingInput(uptime: 100), "phase began, nothing dispatched before it")
        #expect(input.pendingKinds(uptime: 100) == .scrollBegin)
        events.dispatch(timestamp: 100 - 0.003, .scroll(phase: .began, momentum: []))
        events.ages[.scrollWheel] = 0.001
        #expect(!input.hasPendingInput(uptime: 100.0), "a changed tick streams with the fingers")
        events.dispatch(timestamp: 100 - 0.001, .scroll(phase: .changed, momentum: []))
        events.ages[.scrollWheel] = 0.001
        #expect(!input.hasPendingInput(uptime: 100.01))
        // Cancelled: the next scroll begins a gesture.
        events.dispatch(timestamp: 100.01, .scroll(phase: .cancelled, momentum: []))
        events.ages[.scrollWheel] = 0.002
        #expect(input.hasPendingInput(uptime: 100.02))
    }

    /// A free-spinning mouse wheel sends phase-less notches at the pointer's rate: one sequence
    /// while each comes inside the latching window of the last (Chrome's phase handler latches
    /// them), so only the first counts.
    @Test func aStreamOfPhaseLessNotchesIsOneSequence() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events, latching: .init(wheelLatching: 0.5, momentumWait: 0.1))
        events.ages[.scrollWheel] = 0.002
        #expect(input.hasPendingInput(uptime: 100), "the first notch begins a sequence")
        var now = 100.0
        for _ in 0..<40 {
            events.dispatch(timestamp: now - 0.002, .scroll(phase: [], momentum: []))
            now += 0.004
            #expect(!input.hasPendingInput(uptime: now), "every next notch latches into the sequence")
        }
        events.dispatch(timestamp: now - 0.002, .scroll(phase: [], momentum: []))
        now += 0.6
        #expect(input.hasPendingInput(uptime: now), "a notch past the latching window begins the next")
    }

    /// A trackpad fling: phase ended, then momentum began. The momentum continues the gesture (the
    /// phase handler waits for it); the gesture ends at momentum ended.
    @Test func momentumAfterAPhaseEndContinuesTheGesture() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        events.dispatch(timestamp: 99.99, .scroll(phase: .changed, momentum: []))
        events.dispatch(timestamp: 100, .scroll(phase: .ended, momentum: []))
        events.ages[.scrollWheel] = 0.002
        #expect(!input.hasPendingInput(uptime: 100.02), "momentum began, inside the momentum wait")
        events.dispatch(timestamp: 100.018, .scroll(phase: [], momentum: .began))
        events.ages[.scrollWheel] = 0.002
        #expect(!input.hasPendingInput(uptime: 100.4), "momentum changed streams")
        events.dispatch(timestamp: 100.398, .scroll(phase: [], momentum: .ended))
        events.ages[.scrollWheel] = 0.002
        #expect(input.hasPendingInput(uptime: 100.42), "after momentum ended, a scroll begins a gesture")
    }

    /// A phase end with no momentum ends the gesture after the momentum wait.
    @Test func aPhaseEndWithNoMomentumEndsTheGestureAfterTheWait() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events, latching: .init(wheelLatching: 0.5, momentumWait: 0.1))
        events.dispatch(timestamp: 100, .scroll(phase: .ended, momentum: []))
        events.ages[.scrollWheel] = 0.002
        #expect(input.hasPendingInput(uptime: 100.2))
    }

    /// macOS sends a scroll to the window under the pointer, not to the active app: a scroll over
    /// another app's window is not this app's.
    @Test func aScrollOverAnotherAppsWindowDoesNotCount() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        events.pointerIsOverAppWindow = false
        events.ages[.scrollWheel] = 0.002
        #expect(!input.hasPendingInput(uptime: 100))
        events.pointerIsOverAppWindow = true
        #expect(input.hasPendingInput(uptime: 100.000_1))
    }

    /// The app is active, and a whole gesture is generated that AppKit never dispatches here (the
    /// window server latched it to another window): it counts for one stale window from the first
    /// check that saw it, then not, for the rest of the gesture.
    @Test func aScrollGestureTheAppNeverDispatchesStopsCountingAfterTheFirstStaleWindow() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        events.ages[.scrollWheel] = 0.002
        #expect(input.hasPendingInput(uptime: 100))
        #expect(input.hasPendingInput(uptime: 100 + input.staleAfter / 2))
        var now = 100 + input.staleAfter + 0.001
        while now < 101 {
            #expect(!input.hasPendingInput(uptime: now), "the ticks stream on: none of them is ours")
            now += 1.0 / 120
        }
        // A scroll the app dispatches, then a new gesture: it counts again.
        events.dispatch(timestamp: now - 0.004, .scroll(phase: .cancelled, momentum: []))
        #expect(input.hasPendingInput(uptime: now))
    }

    /// The phase-to-sequence mapping, each phase and momentum combination.
    @Test func scrollLatchingKeepsEachSequenceOpenAsChromesPhaseHandlerDoes() {
        let latching = SessionInputPending.ScrollLatching(wheelLatching: 0.5, momentumWait: 0.1)
        func openUntil(_ phase: NSEvent.Phase, _ momentum: NSEvent.Phase) -> TimeInterval {
            latching.sequenceOpen(after: 10, phase: phase, momentum: momentum)
        }
        #expect(openUntil(.began, []) == .infinity)
        #expect(openUntil(.changed, []) == .infinity)
        #expect(openUntil(.stationary, []) == .infinity)
        #expect(openUntil([], .began) == .infinity)
        #expect(openUntil([], .changed) == .infinity)
        #expect(openUntil([], .stationary) == .infinity)
        #expect(openUntil(.ended, []) == 10.1, "a phase end waits for momentum")
        #expect(openUntil([], []) == 10.5, "a wheel notch latches the next")
        #expect(openUntil([], .ended) == 10, "momentum ended closes the gesture")
        #expect(openUntil(.cancelled, []) == 10)
        #expect(openUntil(.mayBegin, []) == 10)
        #expect(openUntil([], .cancelled) == 10)
    }

    // MARK: Drags

    /// A left drag counts while the left button that started it went down in this app, in every
    /// check it is on its way; the budget's own rule gives each class its frame.
    @Test func anActiveDragOfAButtonDownHereIsPending() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        events.ages[.leftMouseDragged] = 0.002
        #expect(!input.hasPendingInput(uptime: 100), "no mouse-down here: another app's or the window server's drag")
        events.dispatch(timestamp: 100.000_5, .leftMouseDown)
        events.ages[.leftMouseDragged] = 0.002
        #expect(input.pendingKinds(uptime: 100.005) == .drag)
        #expect(input.hasPendingInput(uptime: 100.005 + 1.0 / 120))
        events.dispatch(timestamp: 100.003, .leftDrag)
        events.ages[.leftMouseDragged] = 0.002
        #expect(input.hasPendingInput(uptime: 100.03), "the next drag is on its way")
        events.dispatch(timestamp: 100.03, .leftDrag)
        #expect(!input.hasPendingInput(uptime: 100.031), "dispatched: nothing of the drag is on its way")
        events.dispatch(timestamp: 100.031, .leftMouseUp)
        events.ages[.leftMouseDragged] = 0.001
        #expect(!input.hasPendingInput(uptime: 100.035), "the button is up: the drag is over")
    }

    /// A tracking loop takes the drag (a titlebar window move, a dragging session): the local
    /// monitor never sees its drags or its mouse-up. It counts for one stale window, then the drag
    /// is over for this app.
    @Test func aDragATrackingLoopTakesStopsCountingAfterTheFirstStaleWindow() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        events.dispatch(timestamp: 99.99, .leftMouseDown)
        events.ages[.leftMouseDragged] = 0.001
        #expect(input.hasPendingInput(uptime: 100))
        var now = 100 + input.staleAfter + 0.001
        while now < 101 {
            #expect(!input.hasPendingInput(uptime: now), "the window moves: its drags are the window server's")
            now += 1.0 / 60
        }
    }

    /// Through the budget, three frames of a drag the app dispatches as it goes: the drag is
    /// pending at every check (the source has no progress rule of its own), so the visible class
    /// yields in frame 1, runs in frame 2 only by the budget's yielded-last-frame rule, and yields
    /// again in frame 3. Frame 1's check comes late (0.9 of the frame): the next frame still runs.
    @Test func aBatchThatYieldedToADragRunsInTheNextFrameAndYieldsInTheOneAfter() {
        let events = FakeSessionEvents()
        let frame = 1.0 / 60
        let start: UInt64 = 100_000_000_000
        var now = start
        let input = SessionInputPending(events: events)
        let budget = MainFrameBudget(input: input, uptimeNanos: { now })
        func at(_ frames: Double) -> UInt64 { start + UInt64(frames * frame * 1_000_000_000) }
        func seconds(_ nanos: UInt64) -> TimeInterval { TimeInterval(nanos) / 1_000_000_000 }
        events.dispatch(timestamp: seconds(start), .leftMouseDown)

        budget.beginFrame(timestamp: 1, refreshInterval: frame)
        now = at(0.9)
        events.ages[.leftMouseDragged] = 0.001
        #expect(!budget.mayRun(.visible), "the drag event goes before the batch")

        // AppKit dispatches the drag the check saw; the next one is generated just before frame 2.
        events.dispatch(timestamp: seconds(now) - 0.001, .leftDrag)
        now = at(1.0)
        budget.beginFrame(timestamp: 1 + frame, refreshInterval: frame)
        events.ages[.leftMouseDragged] = 0.000_5
        #expect(input.hasPendingInput(uptime: seconds(now)), "the next drag is on its way in frame 2 too")
        #expect(budget.mayRun(.visible), "a batch yielded in one frame does not yield in the next")

        events.dispatch(timestamp: seconds(now) - 0.000_5, .leftDrag)
        now = at(2.0)
        budget.beginFrame(timestamp: 1 + 2 * frame, refreshInterval: frame)
        events.ages[.leftMouseDragged] = 0.000_5
        #expect(!budget.mayRun(.visible), "the frame after, it yields to the drag again")
        #expect(budget.stats.yieldedToInput[0] == 2)
    }

    // MARK: Staleness

    /// Staleness follows the display: two refresh intervals, never less than two 60 Hz frames.
    @Test func anUndispatchedEventIsStaleAfterTwoRefreshIntervalsWithAFloor() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        #expect(abs(input.staleAfter - 2.0 / 60) < 1e-9)
        events.refreshInterval = 1.0 / 120
        #expect(abs(input.staleAfter - SessionInputPending.minimumStaleAfter) < 1e-9, "120 Hz keeps the floor")
        events.refreshInterval = 1.0 / 48
        #expect(abs(input.staleAfter - 2.0 / 48) < 1e-9)
        events.refreshInterval = 0
        #expect(abs(input.staleAfter - 2.0 / 60) < 1e-9, "no refresh interval reported: 60 Hz")
        events.refreshInterval = 1.0 / 60
        events.ages[.keyDown] = 0.040
        #expect(!input.hasPendingInput(uptime: 100), "40 ms is past two 60 Hz frames")
    }

    /// A key that arrives while the main thread is busy for 20 ms (a long first task, a render
    /// pass) on a 120 Hz or 240 Hz display is still pending at the next check: the batch after
    /// the stall yields to it.
    @Test func aKeyBehindATwentyMillisecondStallStillYieldsAtHighRefreshRates() {
        for hertz in [120.0, 240.0] {
            let events = FakeSessionEvents()
            events.refreshInterval = 1 / hertz
            var now: UInt64 = 100_000_000_000
            let budget = MainFrameBudget(input: SessionInputPending(events: events), uptimeNanos: { now })
            budget.beginFrame(timestamp: 1, refreshInterval: 1 / hertz)
            #expect(budget.mayRun(.visible))
            budget.run(.visible, owner: budget.board.owner("stall")) {
                // The key comes at the start of the 20 ms task.
                now += 20_000_000
            }
            events.ages[.keyDown] = 0.020
            #expect(!budget.mayRun(.automation), "\(Int(hertz)) Hz: the key goes before the batch")
        }
    }

    /// The bitset the pending-input state publishes names every kind on its way, while the budget's
    /// check stops at the first.
    @Test func pendingKindsNamesEveryKindOnItsWay() {
        let events = FakeSessionEvents()
        let input = SessionInputPending(events: events)
        events.dispatch(timestamp: 99.99, .leftMouseDown)
        events.ages[.keyDown] = 0.004
        events.ages[.rightMouseDown] = 0.003
        events.ages[.scrollWheel] = 0.002
        events.ages[.leftMouseDragged] = 0.001
        #expect(input.pendingKinds(uptime: 100) == [.key, .click, .scrollBegin, .drag])
        let queries = events.queries
        #expect(input.hasPendingInput(uptime: 100.000_1))
        #expect(events.queries - queries == 2, "the any-input query, then key-down answered it")
        // A publisher's call between the budget's checks does not change what the budget sees.
        #expect(input.pendingKinds(uptime: 100.000_2) == [.key, .click, .scrollBegin, .drag])
        #expect(input.hasPendingInput(uptime: 100.000_3))
        events.isAppActive = false
        #expect(input.pendingKinds(uptime: 100.000_4).isEmpty)
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
        events.dispatch(timestamp: 100.0, .keyOrClick)
        now += 1_000_000  // past the budget's quarter-millisecond reuse of the last answer
        #expect(budget.mayRun(.automation), "dispatched: the batch runs")
        #expect(budget.stats.yieldedToInput[0] == 1 && budget.stats.yieldedToInput[1] == 1)
    }
}

/// The window server and AppKit as ``SessionInputPending`` sees them: event ages by type (the
/// any-input age is the youngest of them), whether the app is active and the pointer over one of
/// its windows, the dispatches a test reports, and how many window-server queries a check made.
@MainActor
private final class FakeSessionEvents: SessionInputEvents {
    var ages: [CGEventType: TimeInterval] = [:]
    var isAppActive = true
    var pointerIsOverAppWindow = true
    var refreshInterval: TimeInterval = 1.0 / 60
    private(set) var observeCalls = 0
    /// Window-server queries made (each is one synchronous call on the main thread in the app).
    private(set) var queries = 0
    private var dispatched: (@MainActor @Sendable (SessionInputPending.Dispatched) -> Void)?

    func secondsSinceLastInput() -> TimeInterval {
        queries += 1
        return ages.values.min() ?? 10_000
    }

    func secondsSinceLastEvent(_ type: CGEventType) -> TimeInterval {
        queries += 1
        return ages[type] ?? 10_000
    }

    func observeDispatch(_ dispatched: @escaping @MainActor @Sendable (SessionInputPending.Dispatched) -> Void) {
        observeCalls += 1
        self.dispatched = dispatched
    }

    /// AppKit dispatched an input event of `kind` with `timestamp` (seconds since boot).
    func dispatch(timestamp: TimeInterval, _ kind: SessionInputPending.Dispatched.Kind) {
        dispatched?(SessionInputPending.Dispatched(timestamp: timestamp, kind: kind))
    }
}
