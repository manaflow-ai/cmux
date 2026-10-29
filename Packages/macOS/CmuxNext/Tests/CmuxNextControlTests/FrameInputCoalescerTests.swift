import AppKit
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Continuous input coalesced to the window's frame (FrameInputCoalescer.swift; Chromium's
/// main_thread_event_queue.cc): one body per owner and kind per frame with every event and the
/// summed delta, unbuffered owners, discrete flushes and the one-frame fallback.
@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameInputCoalescerTests {
    /// A frame's ten drags run one body: the latest drag, all ten in order, and the sum of their
    /// deltas (a coalescer that kept only the latest would lose nine tenths of the motion).
    @Test func tenDragsInAFrameRunOneBodyWithTheSummedDelta() throws {
        let (scheduler, _) = Self.scheduler()
        let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: WakeupLedger())
        var calls: [Delivery] = []
        for index in 0..<10 {
            coalescer.post(.drag, owner: "drag", sample: Self.sample(index)) { latest, coalesced, delta in
                calls.append(Delivery(latest: latest, coalesced: coalesced, delta: delta))
            }
        }
        #expect(calls.isEmpty, "nothing runs before the frame")
        #expect(coalescer.hasPending)
        scheduler.frameDidFire(timestamp: 1000, refreshInterval: 1.0 / 120)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.coalesced.count == 10)
        #expect(call.coalesced == (0..<10).map(Self.sample))
        #expect(call.latest == Self.sample(9))
        #expect(call.delta == CGVector(dx: 10, dy: 20))
        #expect(!coalescer.hasPending)
        coalescer.invalidate()
    }

    /// Owners and kinds do not merge: a frame with drags of two owners and a scroll runs three
    /// bodies, in the order of their first post.
    @Test func ownersAndKindsRunOneBodyEachInFirstPostOrder() {
        let (scheduler, _) = Self.scheduler()
        let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: WakeupLedger())
        var log: [String] = []
        coalescer.post(.drag, owner: "a", sample: Self.sample(0)) { _, coalesced, _ in log.append("a.drag \(coalesced.count)") }
        coalescer.post(.scroll, owner: "a", sample: Self.sample(1)) { _, coalesced, _ in log.append("a.scroll \(coalesced.count)") }
        coalescer.post(.drag, owner: "b", sample: Self.sample(2)) { _, coalesced, _ in log.append("b.drag \(coalesced.count)") }
        coalescer.post(.drag, owner: "a", sample: Self.sample(3)) { _, coalesced, _ in log.append("a.drag \(coalesced.count)") }
        scheduler.frameDidFire(timestamp: 1000, refreshInterval: 1.0 / 120)
        #expect(log == ["a.drag 2", "a.scroll 1", "b.drag 1"])
        coalescer.invalidate()
    }

    /// An owner that asked for unbuffered delivery gets every drag at once until the pointer goes
    /// up; after that its drags wait for the frame again.
    @Test func anUnbufferedOwnerGetsEveryEventUntilPointerUp() {
        let (scheduler, _) = Self.scheduler()
        let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: WakeupLedger())
        var calls: [Delivery] = []
        coalescer.requestUnbufferedUntilPointerUp(owner: "resize")
        for index in 0..<10 {
            coalescer.post(.drag, owner: "resize", sample: Self.sample(index)) { latest, coalesced, delta in
                calls.append(Delivery(latest: latest, coalesced: coalesced, delta: delta))
            }
        }
        #expect(calls.count == 10)
        #expect(calls.allSatisfy { $0.coalesced.count == 1 && $0.delta == CGVector(dx: 1, dy: 2) })
        #expect(!coalescer.hasPending)
        coalescer.pointerUp()
        coalescer.post(.drag, owner: "resize", sample: Self.sample(10)) { latest, coalesced, delta in
            calls.append(Delivery(latest: latest, coalesced: coalesced, delta: delta))
        }
        #expect(calls.count == 10, "after pointer up the drag waits for the frame")
        scheduler.frameDidFire(timestamp: 1000, refreshInterval: 1.0 / 120)
        #expect(calls.count == 11)
        coalescer.invalidate()
    }

    /// A discrete event's handler runs after the moves that came before it (ShouldFlushQueue).
    @Test func aDiscreteFlushRunsPendingWorkFirst() {
        let (scheduler, _) = Self.scheduler()
        let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: WakeupLedger())
        var log: [String] = []
        for index in 0..<3 {
            coalescer.post(.pointerMove, owner: "hover", sample: Self.sample(index)) { _, coalesced, _ in
                log.append("hover \(coalesced.count)")
            }
        }
        coalescer.flushBeforeDiscreteInput()
        log.append("key")
        #expect(log == ["hover 3", "key"])
        scheduler.frameDidFire(timestamp: 1000, refreshInterval: 1.0 / 120)
        #expect(log == ["hover 3", "key"], "the flushed work does not run again at the frame")
        coalescer.invalidate()
    }

    /// The application's hook (`sendEvent`): a key-down flushes the window's pending moves, a
    /// move passes, and a mouse-up ends unbuffered delivery.
    @Test func theApplicationHookFlushesOnDiscreteEventsAndEndsUnbufferedOnMouseUp() {
        let (scheduler, _) = Self.scheduler()
        // The window's scheduler stands in for FrameScheduler.forWindow (no display link in tests).
        let coalescers = FrameInputCoalescers { _ in scheduler.input }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let coalescer = coalescers.coalescer(for: window)
        #expect(coalescers.coalescer(for: window) === coalescer, "one coalescer per window")
        var log: [String] = []
        coalescer.post(.pointerMove, owner: "hover", sample: Self.sample(0)) { _, _, _ in log.append("hover") }
        #expect(coalescers.hasPending)
        coalescers.willDispatch(.mouseMoved)
        #expect(log.isEmpty, "a move is continuous: it does not flush")
        coalescers.willDispatch(.keyDown)
        #expect(log == ["hover"])
        #expect(!coalescers.hasPending)

        coalescer.requestUnbufferedUntilPointerUp(owner: "drag")
        coalescers.willDispatch(.leftMouseUp)
        coalescer.post(.drag, owner: "drag", sample: Self.sample(1)) { _, _, _ in log.append("drag") }
        #expect(log == ["hover"], "the mouse-up ended unbuffered delivery")
        #expect(coalescers.hasPending)
        // The window closed: its scheduler invalidates, and the scheduler's coalescer drops its work.
        scheduler.invalidate()
        #expect(!coalescers.hasPending, "a closed window's work is dropped")
        coalescers.willDispatch(.keyDown)
        #expect(log == ["hover"], "dropped work never runs")
    }

    /// The window's input runs in the frame tick before its frame clients, so an autoscroll or a
    /// spring of the same frame sees the frame's pointer.
    @Test func inputRunsBeforeTheFrameClientsOfTheSameTick() {
        let (scheduler, _) = Self.scheduler()
        let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: WakeupLedger())
        var log: [String] = []
        var springs: [FrameClient] = []
        for index in 0..<8 {
            let spring = FrameClient(owner: "spring \(index)", on: scheduler) { _ in log.append("frame"); return false }
            spring.activate()
            springs.append(spring)
        }
        coalescer.post(.drag, owner: "drag", sample: Self.sample(0)) { _, _, _ in log.append("input") }
        scheduler.frameDidFire(timestamp: 1000, refreshInterval: 1.0 / 120)
        #expect(log.first == "input")
        #expect(log.count == 9)
        coalescer.invalidate()
        _ = springs
    }

    /// A frame client the input stage wakes ticks in the same frame: a ghost spring
    /// that settled while the pointer rested, woken by the frame's move, steps at this vsync, not the
    /// next (Blink's `WidgetBase::BeginMainFrame` dispatches rAF-aligned input before the frame's rAF).
    /// One a frame client wakes ticks next frame.
    @Test func aFrameClientTheInputWakesTicksInTheSameFrame() {
        let (scheduler, _) = Self.scheduler()
        let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: WakeupLedger())
        var log: [String] = []
        let late = FrameClient(owner: "late", on: scheduler) { _ in log.append("late"); return false }
        let spring = FrameClient(owner: "spring", on: scheduler) { _ in
            log.append("spring")
            late.activate()
            return false
        }
        // The spring is idle; the coalescer's client keeps the scheduler on its display.
        coalescer.post(.drag, owner: "drag", sample: Self.sample(0)) { _, _, _ in
            log.append("input")
            spring.activate()
        }
        scheduler.frameDidFire(timestamp: 1000, refreshInterval: 1.0 / 120)
        #expect(log == ["input", "spring"], "the woken spring did not tick in the input's frame: \(log)")
        scheduler.frameDidFire(timestamp: 1000 + 1.0 / 120, refreshInterval: 1.0 / 120)
        #expect(log == ["input", "spring", "late"])
        coalescer.invalidate()
    }

    /// With the display link stopped, the one-frame fallback delivers the frame's posts once, and no
    /// timer stays armed after it.
    @Test func withTheLinkDownTheFallbackFiresOnce() async throws {
        let (scheduler, _) = Self.scheduler(linkRuns: false)
        let clock = ManualClock()
        let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: clock, ledger: WakeupLedger())
        let (delivered, deliver) = AsyncStream.makeStream(of: Int.self)
        for index in 0..<10 {
            coalescer.post(.drag, owner: "drag", sample: Self.sample(index)) { _, coalesced, _ in deliver.yield(coalesced.count) }
        }
        #expect(coalescer.isFallbackArmed)
        try await clock.waitForSleeper()
        clock.advance(by: FrameInputCoalescer.defaultFrameInterval)
        var iterator = delivered.makeAsyncIterator()
        let count = await iterator.next()
        #expect(count == 10)
        #expect(coalescer.fallbackFires == 1)
        #expect(!coalescer.isFallbackArmed)
        #expect(clock.sleeperCount == 0, "nothing re-armed after the fallback")
        coalescer.invalidate()
        deliver.finish()
    }

    /// While the link runs, input costs no fallback timer, from the first post of a burst on: the
    /// coalescer keeps ticking one frame past its last delivery, and a post in that frame arms nothing.
    @Test func aTickingLinkArmsNoFallback() {
        let (scheduler, _) = Self.scheduler()
        let clock = ManualClock()
        let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: clock, ledger: WakeupLedger())
        var calls = 0
        coalescer.post(.pointerMove, owner: "hover", sample: Self.sample(0)) { _, _, _ in calls += 1 }
        #expect(!coalescer.isFallbackArmed, "a running link arms no fallback, even before its first tick")
        scheduler.frameDidFire(timestamp: 1000, refreshInterval: 1.0 / 120)
        #expect(!coalescer.isFallbackArmed)
        for frame in 1...5 {
            coalescer.post(.pointerMove, owner: "hover", sample: Self.sample(frame)) { _, _, _ in calls += 1 }
            #expect(!coalescer.isFallbackArmed)
            scheduler.frameDidFire(timestamp: 1000 + Double(frame) / 120, refreshInterval: 1.0 / 120)
        }
        #expect(calls == 6)
        #expect(coalescer.fallbackFires == 0)
        #expect(coalescer.frameFlushes == 6)
        #expect(clock.sleepRequests.isEmpty, "no timer task was made")
        coalescer.invalidate()
    }

    // MARK: Support

    private struct Delivery {
        let latest: FrameInputSample
        let coalesced: [FrameInputSample]
        let delta: CGVector
    }

    private static func sample(_ index: Int) -> FrameInputSample {
        FrameInputSample(location: CGPoint(x: index, y: index * 2), delta: CGVector(dx: 1, dy: 2), timestamp: TimeInterval(index))
    }

    /// A scheduler whose link only ticks when the test says, and whose stall timer never fires
    /// (its clock is never advanced), so every frame in a test is one the test delivered. `linkRuns`
    /// false: the link stays paused, as an occluded window's does.
    private static func scheduler(linkRuns: Bool = true) -> (FrameScheduler, ManualClock) {
        let stallClock = ManualClock()
        let scheduler = FrameScheduler.testing(clock: stallClock, ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in
            CoalescerFakeLink(runs: linkRuns)
        }
        return (scheduler, stallClock)
    }
}

@MainActor
private final class CoalescerFakeLink: FrameLink {
    private let runs: Bool
    private var paused = false

    init(runs: Bool) { self.runs = runs }

    var isPaused: Bool {
        get { paused || !runs }
        set { paused = newValue }
    }

    func invalidate() {}
}
