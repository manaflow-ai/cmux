import AppKit
import CmuxNextInput
import CmuxNextInputCore
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A window's pointer consumers on its one FrameInputCoalescer (Chromium's
/// main_thread_event_queue.cc): leading edge at once, one merged trailing delivery per run at the tick,
/// in the input stage before the frame clients; discrete input flushes first; the fallback delivers
/// only while the link does not run; a closed window drops its input; an idle window holds no client,
/// link or timer.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct PointerFrameCoalescerTests {
    /// What deliveries a consumer got: a class, so `@MainActor` bodies share it without a captured `var`.
    final class Log {
        var inputs: [PointerCoalescedInput] = []
        var events: [String] = []
        var latestX = -1.0
        /// The frames a frame-timed consumer's deliveries were drawn in.
        var frames: [PointerFrameTime] = []
        /// The consumer whose body posts to itself.
        var consumer: PointerFrameConsumer?
    }

    // MARK: Idle and leading edge

    @Test func idleHoldsNoClientNoLinkAndNoTimer() {
        let rig = Rig()
        let log = Log()
        let consumer = rig.coalescer.consumer(owner: "hover") { log.inputs.append($0) }
        #expect(!rig.coalescer.isTicking)
        #expect(!rig.scheduler.hasLink)
        #expect(!rig.coalescer.isFallbackArmed)

        for index in 0..<4 { consumer.post(Self.move(x: index)) }
        rig.tick(1)
        #expect(rig.coalescer.isTicking, "the frame after input ticks once more for the next interval")
        rig.tick(2)
        #expect(!rig.coalescer.isTicking, "a frame after an interval with no input goes idle")
        #expect(!rig.scheduler.hasLink, "the idle window left its display: no link")
        #expect(!rig.coalescer.isFallbackArmed)
        rig.coalescer.invalidate()
    }

    /// A lone move after an idle frame is delivered in the same turn, not at the next frame.
    @Test func aSingleMoveAfterAnIdleFrameIsDeliveredInTheSameTurn() throws {
        let rig = Rig()
        let log = Log()
        let consumer = rig.coalescer.consumer(owner: "hover") { log.inputs.append($0) }
        consumer.post(Self.move(x: 7))
        let input = try #require(log.inputs.first)
        #expect(log.inputs.count == 1)
        #expect(input.latest.location.x == 7)
        #expect(input.coalescedCount == 1)
        #expect(!rig.coalescer.hasPending)
        #expect(!rig.coalescer.isFallbackArmed, "nothing waits, so no fallback")
        rig.tick(1)
        #expect(log.inputs.count == 1, "the frame has nothing left to deliver")
        rig.coalescer.invalidate()
    }

    /// A view posts its NSEvent: moves, drags and scrolls go in, anything else is refused.
    @Test func aViewPostsContinuousNSEventsOnly() throws {
        _ = NSApplication.shared
        let rig = Rig()
        let log = Log()
        let consumer = rig.coalescer.consumer(owner: "hover") { log.inputs.append($0) }
        let move = try Self.mouse(.mouseMoved)
        let down = try Self.mouse(.leftMouseDown)
        #expect(consumer.post(move))
        #expect(!consumer.post(down), "a button is discrete")
        #expect(log.inputs.map(\.kind) == [.move])
        rig.coalescer.invalidate()
    }

    // MARK: Per frame

    /// Eight drags in one frame: the first at once, the other seven merged into one trailing delivery
    /// that carries their count, the oldest time and every point.
    @Test func eightDragsInAFrameMakeTwoDeliveries() throws {
        let rig = Rig()
        let log = Log()
        let consumer = rig.coalescer.consumer(owner: "divider") { log.inputs.append($0) }
        for index in 0..<8 { consumer.post(Self.drag(x: index, at: 100 + Double(index))) }
        #expect(log.inputs.count == 1, "the leading drag")
        rig.tick(1)
        #expect(log.inputs.count == 2)
        let trailing = try #require(log.inputs.last)
        #expect(trailing.coalescedCount == 7)
        #expect(trailing.oldestTimestamp == 101, "the oldest generated time reaches the consumer")
        #expect(trailing.samples.map(\.location.x) == (1..<8).map { Double($0) })
        #expect(trailing.latest.location.x == 7)
        #expect(consumer.maxDeliveriesPerFrame == 2)
        rig.coalescer.invalidate()
    }

    /// A frame-timed consumer gets the frame each delivery is drawn in: the frame tick's
    /// time and refresh interval for the trailing delivery (Chromium's `DispatchRafAlignedInput(frame_time)`),
    /// the newest event's own time for a delivery that goes out at once (the leading edge, a flush).
    @Test func aFrameTimedConsumerGetsTheTicksTimeAtTheFrameAndTheEventsTimeAtOnce() throws {
        let rig = Rig()
        let log = Log()
        let consumer = rig.coalescer.frameTimedConsumer(owner: "divider") { _, frame in log.frames.append(frame) }
        for index in 0..<4 { consumer.post(Self.drag(x: index, at: 100 + Double(index))) }
        let leading = try #require(log.frames.first)
        #expect(log.frames.count == 1)
        #expect(leading.time == 100, "a leading edge has no frame yet: its own event's time")
        rig.tick(1)
        let trailing = try #require(log.frames.last)
        #expect(log.frames.count == 2)
        #expect(trailing.time == 1000 + 1.0 / 120, "the trailing delivery is drawn in the tick's frame")
        #expect(trailing.interval == 1.0 / 120)
        consumer.post(Self.drag(x: 9, at: 200))
        consumer.post(Self.drag(x: 10, at: 201))
        consumer.flush()
        #expect(log.frames.last?.time == 201, "a flush is not a frame: the newest event's time")
        #expect(log.frames.last?.interval == 1.0 / 120, "the interval is the last tick's")
        rig.coalescer.invalidate()
    }

    /// A steady drag across frames never gets more than two deliveries in a frame interval, a running
    /// link arms no fallback, and the drag's sample buffers are reused rather than made per frame.
    @Test func aSteadyDragStaysAtTwoDeliveriesPerFrameWithNoFallback() {
        let rig = Rig()
        let log = Log()
        let consumer = rig.coalescer.consumer(owner: "divider") { log.events.append("\($0.coalescedCount)") }
        var x = 0
        for frame in 1...6 {
            for _ in 0..<5 {
                consumer.post(Self.drag(x: x))
                x += 1
            }
            #expect(!rig.coalescer.isFallbackArmed, "the link runs: no timer")
            rig.tick(frame)
        }
        #expect(consumer.maxDeliveriesPerFrame == 2)
        #expect(log.events.count == 12)
        #expect(log.events.compactMap(Int.init).reduce(0, +) == 30, "every event is in some delivery")
        #expect(rig.coalescer.fallbackFires == 0)
        #expect(consumer.spareSampleBuffers > 0, "delivered drags gave their sample storage back")
        rig.coalescer.invalidate()
    }

    /// Scroll sums keep their phases: began, the summed changes and ended are separate deliveries.
    @Test func scrollSumsKeepPhaseBoundaries() {
        let rig = Rig()
        let log = Log()
        let consumer = rig.coalescer.consumer(owner: "scroller") { log.inputs.append($0) }
        consumer.post(Self.scroll(.began, dy: 1))
        for dy in [2.0, 3.0, 4.0] { consumer.post(Self.scroll(.changed, dy: dy)) }
        consumer.post(Self.scroll(.ended, dy: 0))
        rig.tick(1)
        #expect(log.inputs.map(\.latest.scrollPhase) == [.began, .changed, .ended])
        #expect(log.inputs.map(\.scrollDelta.y) == [1, 9, 0])
        #expect(log.inputs.map(\.coalescedCount) == [1, 3, 1])
        rig.coalescer.invalidate()
    }

    /// Input that does not merge adds one delivery per run: a leading move, then a drag and a move
    /// make three deliveries in the interval, the bound `maxDeliveriesPerFrame` reports.
    @Test func inputOfMixedKindsAddsOneDeliveryPerRun() {
        let rig = Rig()
        let log = Log()
        let consumer = rig.coalescer.consumer(owner: "pointer") { log.inputs.append($0) }
        consumer.post(Self.move(x: 0))
        consumer.post(Self.drag(x: 1))
        consumer.post(Self.drag(x: 2))
        consumer.post(Self.move(x: 3))
        rig.tick(1)
        #expect(log.inputs.map(\.kind) == [.move, .drag, .move])
        #expect(consumer.maxDeliveriesPerFrame == 3)
        rig.coalescer.invalidate()
    }

    /// A discrete flush in the middle of a frame ends the interval: the drags after a modifier change
    /// start a new one, so no interval gets more than two deliveries.
    @Test func aDiscreteFlushMidFrameStartsANewInterval() {
        let rig = Rig()
        let log = Log()
        let consumer = rig.coalescer.consumer(owner: "divider") { log.inputs.append($0) }
        consumer.post(Self.drag(x: 0))
        consumer.post(Self.drag(x: 1))
        rig.coalescer.flushBeforeDiscreteInput()
        #expect(log.inputs.count == 2)
        consumer.post(Self.drag(x: 2, modifiers: .shift))
        #expect(log.inputs.count == 3, "the first drag after the flush is a leading edge")
        consumer.post(Self.drag(x: 3, modifiers: .shift))
        consumer.post(Self.drag(x: 4, modifiers: .shift))
        rig.tick(1)
        #expect(log.inputs.map(\.latest.location.x) == [0, 1, 2, 4])
        #expect(consumer.maxDeliveriesPerFrame == 2)
        rig.coalescer.invalidate()
    }

    /// A low-latency consumer gets every event at once, never merged.
    @Test func aLowLatencyConsumerIsNeverCoalesced() {
        let rig = Rig()
        let log = Log()
        let consumer = rig.coalescer.consumer(owner: "stroke", lowLatency: true) { log.inputs.append($0) }
        for index in 0..<5 { consumer.post(Self.drag(x: index)) }
        #expect(log.inputs.count == 5)
        #expect(log.inputs.allSatisfy { $0.coalescedCount == 1 })
        #expect(!rig.coalescer.hasPending)
        #expect(!rig.coalescer.isTicking, "nothing waits for a frame")
        rig.coalescer.invalidate()
    }

    // MARK: Frame order

    /// The trailing delivery runs in the input stage, before every frame client of the same tick, so
    /// a spring or an autoscroll of that frame reads this frame's pointer whatever its hash order.
    @Test func theFrameClientsOfTheSameTickSeeTheTrailingDelivery() {
        let rig = Rig()
        let log = Log()
        let consumer = rig.coalescer.consumer(owner: "divider") { log.latestX = $0.latest.location.x }
        var springs: [FrameClient] = []
        for index in 0..<8 {
            let spring = FrameClient(owner: "spring \(index)", on: rig.scheduler) { _ in
                log.events.append("\(Int(log.latestX))")
                return false
            }
            spring.activate()
            springs.append(spring)
        }
        consumer.post(Self.drag(x: 0))
        consumer.post(Self.drag(x: 5))
        rig.tick(1)
        #expect(log.events == Array(repeating: "5", count: 8))
        rig.coalescer.invalidate()
        withExtendedLifetime(springs) {}
    }

    /// The trailing delivery runs in the window's input stage, before the frame's springs and drivers,
    /// and a client it wakes ticks in the same frame (Blink dispatches rAF-aligned input
    /// before the frame's rAF, `WidgetBase::BeginMainFrame`): a drag whose ghost settled shows the
    /// frame's move at this vsync, not the next.
    @Test func theTrailingDeliveryRunsBeforeTheFrameAndWakesItsClientsThisFrame() {
        let rig = Rig()
        let log = Log()
        var springs: [FrameClient] = []
        for index in 0..<4 {
            let spring = FrameClient(owner: "spring \(index)", on: rig.scheduler) { _ in log.events.append("frame"); return false }
            spring.activate()
            springs.append(spring)
        }
        let ghost = FrameClient(owner: "ghost", on: rig.scheduler) { _ in log.events.append("ghost"); return false }
        let consumer = rig.coalescer.consumer(owner: "drag") { input in
            guard input.coalescedCount > 1 else { return log.events.append("leading") }
            log.events.append("trailing")
            ghost.activate()
        }
        for index in 0..<3 { consumer.post(Self.drag(x: index, at: 100 + Double(index))) }
        #expect(log.events == ["leading"])
        rig.tick(1)
        #expect(log.events.dropFirst().first == "trailing", "a frame client ran before the frame's input: \(log.events)")
        #expect(log.events.filter { $0 == "frame" }.count == 4)
        #expect(log.events.last == "ghost", "the client the trailing delivery woke did not tick this frame: \(log.events)")
        rig.coalescer.invalidate()
        _ = springs
    }

    // MARK: Discrete input

    /// The application's hook flushes a consumer's pending moves before a button, and keyed posts and
    /// consumers share one arrival order.
    @Test func theApplicationHookFlushesConsumersAndKeyedPostsInArrivalOrder() {
        let rig = Rig()
        let coalescers = FrameInputCoalescers { [coalescer = rig.coalescer] _ in coalescer }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let coalescer = coalescers.coalescer(for: window)
        let log = Log()
        let hover = coalescer.consumer(owner: "hover") { log.events.append("move \(Int($0.latest.location.x)) x\($0.coalescedCount)") }
        hover.post(Self.move(x: 0))
        let sample = FrameInputSample(location: .zero, delta: .zero, timestamp: 1)
        coalescer.post(.drag, owner: "keyed", sample: sample) { _, _, _ in log.events.append("keyed") }
        hover.post(Self.move(x: 1))
        hover.post(Self.move(x: 2))
        #expect(coalescers.hasPending)
        coalescers.willDispatch(.mouseMoved)
        #expect(log.events == ["move 0 x1"], "a move is continuous: it does not flush")
        coalescers.willDispatch(.leftMouseDown)
        #expect(log.events == ["move 0 x1", "keyed", "move 2 x2"])
        #expect(!coalescers.hasPending)
        rig.tick(1)
        #expect(log.events.count == 3, "the flushed input does not run again at the frame")
        rig.coalescer.invalidate()
    }

    /// A consumer's own flush (its mouse-up) runs only its own input and starts its next interval.
    @Test func aConsumersFlushRunsOnlyItsOwnInput() {
        let rig = Rig()
        let log = Log()
        let first = rig.coalescer.consumer(owner: "a") { _ in log.events.append("a") }
        let second = rig.coalescer.consumer(owner: "b") { _ in log.events.append("b") }
        first.post(Self.drag(x: 0))
        second.post(Self.move(x: 0))
        log.events.removeAll()
        second.post(Self.move(x: 1))
        first.post(Self.drag(x: 1))
        first.flush()
        #expect(log.events == ["a"])
        #expect(second.hasPending)
        first.post(Self.drag(x: 2))
        #expect(log.events == ["a", "a"], "after its flush the next drag is a leading edge")
        rig.coalescer.flushBeforeDiscreteInput()
        #expect(log.events == ["a", "a", "b"])
        #expect(!rig.coalescer.hasPending)
        rig.coalescer.invalidate()
    }

    // MARK: Re-entry, cancel and close

    /// Input a body posts during its trailing delivery waits for the next frame, and the client keeps
    /// ticking for it.
    @Test func aPostFromATrailingDeliveryWaitsForTheNextFrame() {
        let rig = Rig()
        let log = Log()
        let consumer = rig.coalescer.consumer(owner: "divider") { input in
            log.inputs.append(input)
            if input.latest.location.x == 1 { log.consumer?.post(Self.drag(x: 9)) }
        }
        log.consumer = consumer
        consumer.post(Self.drag(x: 0))
        consumer.post(Self.drag(x: 1))
        rig.tick(1)
        #expect(log.inputs.map(\.latest.location.x) == [0, 1])
        #expect(rig.coalescer.hasPending)
        #expect(rig.coalescer.isTicking)
        rig.tick(2)
        #expect(log.inputs.map(\.latest.location.x) == [0, 1, 9])
        #expect(consumer.maxDeliveriesPerFrame == 2)
        rig.coalescer.invalidate()
    }

    /// Cancel drops the pending input: the frame delivers nothing, and no fallback is left.
    @Test func cancelDropsPendingInputAndTheFallback() {
        let rig = Rig(linkTicks: false)
        let log = Log()
        let consumer = rig.coalescer.consumer(owner: "hover") { log.inputs.append($0) }
        consumer.post(Self.move(x: 0))
        consumer.post(Self.move(x: 1))
        #expect(rig.coalescer.isFallbackArmed)
        consumer.cancel()
        #expect(!consumer.hasPending)
        #expect(!rig.coalescer.hasPending)
        #expect(!rig.coalescer.isFallbackArmed)
        consumer.post(Self.move(x: 2))
        #expect(log.inputs.map(\.latest.location.x) == [0, 2], "after a cancel the next move is a leading edge")
        rig.coalescer.invalidate()
    }

    /// The window closed: its scheduler invalidates its coalescer and the pending input, the fallback
    /// and the client go; shown again, the window posts to the same coalescer on its own scheduler.
    @Test func aClosedWindowDropsItsPendingInput() {
        let rig = Rig()
        let log = Log()
        let coalescer = rig.scheduler.input
        let consumer = coalescer.consumer(owner: "hover") { log.inputs.append($0) }
        consumer.post(Self.move(x: 0))
        consumer.post(Self.move(x: 1))
        rig.scheduler.invalidate()
        #expect(!coalescer.hasPending)
        #expect(!coalescer.isTicking)
        #expect(!coalescer.isFallbackArmed)
        #expect(rig.scheduler.activeClients.isEmpty)
        #expect(!rig.scheduler.hasLink)
        rig.tick(1)
        #expect(log.inputs.count == 1, "the dropped moves never run")

        #expect(rig.scheduler.input === coalescer, "a window shown again keeps its coalescer")
        consumer.post(Self.move(x: 2))
        #expect(log.inputs.last?.latest.location.x == 2)
        #expect(rig.scheduler.activeClients == ["FrameInputCoalescer"], "it ticks on the window's scheduler")
        coalescer.invalidate()
    }

    /// A coalescer whose scheduler is gone drops every post: it never ticks on another scheduler.
    @Test func aPostAfterTheSchedulerIsGoneIsDropped() {
        let made = Self.coalescerOfAReleasedScheduler()
        #expect(made.scheduler.value == nil)
        let log = Log()
        let consumer = made.coalescer.consumer(owner: "hover") { log.inputs.append($0) }
        consumer.post(Self.move(x: 0))
        consumer.post(Self.move(x: 1))
        #expect(log.inputs.isEmpty)
        #expect(!made.coalescer.hasPending)
        #expect(!made.coalescer.isTicking)
        #expect(!made.coalescer.isFallbackArmed)
    }

    // MARK: Fallback

    /// A link that already runs for another client arms no fallback for a new burst.
    @Test func aRunningLinkArmsNoFallbackForANewBurst() {
        let rig = Rig()
        let spring = FrameClient(owner: "spring", on: rig.scheduler) { _ in true }
        spring.activate()
        rig.tick(1)
        let consumer = rig.coalescer.consumer(owner: "hover") { _ in }
        consumer.post(Self.move(x: 0))
        consumer.post(Self.move(x: 1))
        consumer.post(Self.drag(x: 2))
        #expect(rig.coalescer.hasPending)
        #expect(!rig.coalescer.isFallbackArmed)
        #expect(rig.fallbackClock.sleepRequests.isEmpty, "no timer task was made")
        spring.deactivate()
        rig.coalescer.invalidate()
    }

    /// An occluded window's link does not run: a pending drag still goes out one refresh interval
    /// later, exactly (a precise deadline), through the fallback, and no timer stays armed after it.
    @Test func anOccludedWindowsFakeLinkStillDelivers() async throws {
        let rig = Rig(linkTicks: false)
        let (delivered, deliver) = AsyncStream.makeStream(of: PointerCoalescedInput.self)
        let consumer = rig.coalescer.consumer(owner: "divider") { deliver.yield($0) }
        var iterator = delivered.makeAsyncIterator()
        consumer.post(Self.drag(x: 0))
        _ = await iterator.next()
        #expect(!rig.coalescer.isFallbackArmed, "the leading drag waits for nothing")
        consumer.post(Self.drag(x: 1))
        consumer.post(Self.drag(x: 2))
        #expect(rig.coalescer.isFallbackArmed, "pending input and a link that is not running")
        try await rig.fallbackClock.waitForSleeper()
        let request = try #require(rig.fallbackClock.sleepRequests.last)
        #expect(request.deadline.offset == FrameInputCoalescer.defaultFrameInterval, "a drag waits one refresh interval")
        #expect(request.tolerance == .zero, "with no wake leeway after it")
        rig.fallbackClock.advance(by: FrameInputCoalescer.defaultFrameInterval)
        let trailing = await iterator.next()
        #expect(trailing?.coalescedCount == 2)
        #expect(rig.coalescer.fallbackFires == 1)
        #expect(!rig.coalescer.isFallbackArmed)
        #expect(rig.fallbackClock.sleeperCount == 0)
        rig.coalescer.invalidate()
        deliver.finish()
    }

    /// Without a drag the fallback is Chrome's kMaxRafDelay, five seconds.
    @Test func pendingMovesWithNoLinkWaitTheIdleFallback() async throws {
        let rig = Rig(linkTicks: false)
        let log = Log()
        let consumer = rig.coalescer.consumer(owner: "hover") { log.inputs.append($0) }
        consumer.post(Self.move(x: 0))
        consumer.post(Self.move(x: 1))
        #expect(rig.coalescer.isFallbackArmed)
        try await rig.fallbackClock.waitForSleeper()
        #expect(rig.fallbackClock.sleepRequests.last?.deadline.offset == FrameInputCoalescer.idleFallbackDelay)
        consumer.flush()
        #expect(!rig.coalescer.isFallbackArmed, "nothing pending: the fallback is cancelled")
        #expect(log.inputs.count == 2)
        rig.coalescer.invalidate()
    }

    /// A stopped link's window ticks on its display's stall deadline (refreshInterval nil, off the
    /// link): that tick delivers the pending moves before the idle fallback would.
    @Test func aStallTickDeliversWhenTheLinkIsStopped() async throws {
        let rig = Rig(linkTicks: false)
        let (delivered, deliver) = AsyncStream.makeStream(of: PointerCoalescedInput.self)
        let consumer = rig.coalescer.consumer(owner: "hover") { deliver.yield($0) }
        var iterator = delivered.makeAsyncIterator()
        consumer.post(Self.move(x: 0))
        _ = await iterator.next()
        consumer.post(Self.move(x: 1))
        consumer.post(Self.move(x: 2))
        #expect(rig.coalescer.isFallbackArmed)
        try await rig.stallClock.waitForSleeper()
        rig.time.now += 0.5
        rig.stallClock.advance(by: .milliseconds(200))
        let trailing = await iterator.next()
        #expect(trailing?.latest.location.x == 2)
        #expect(rig.scheduler.ticksOffLink, "the stall deadline ticked it, not the link")
        #expect(rig.coalescer.frameFlushes == 1)
        #expect(rig.coalescer.fallbackFires == 0)
        #expect(!rig.coalescer.isFallbackArmed)
        rig.coalescer.invalidate()
        deliver.finish()
    }

    // MARK: Support

    /// A weak reference to a scheduler (the test reads whether it was released).
    @MainActor
    final class WeakScheduler {
        weak var value: FrameScheduler?
    }

    /// A coalescer made on a scheduler nothing holds any more.
    private static func coalescerOfAReleasedScheduler() -> (coalescer: FrameInputCoalescer, scheduler: WeakScheduler) {
        let weak = WeakScheduler()
        let coalescer = Self.coalescer(recordingIn: weak)
        return (coalescer, weak)
    }

    private static func coalescer(recordingIn weak: WeakScheduler) -> FrameInputCoalescer {
        let scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in
            CoalescerTestLink()
        }
        weak.value = scheduler
        return FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: WakeupLedger())
    }

    /// The media time the rig's display clock reads (a class: the clock's closure reads it live).
    @MainActor
    final class MediaTime {
        var now: Double = 1000
    }

    /// A window scheduler on a fake link that runs and ticks only when the test says (`linkTicks`), or
    /// stays paused as an occluded window's does; its stall deadline fires only when the test moves
    /// `stallClock`, and the coalescer's fallback only when it moves `fallbackClock`.
    @MainActor
    struct Rig {
        let scheduler: FrameScheduler
        let stallClock: ManualClock
        let fallbackClock: ManualClock
        let time: MediaTime
        let coalescer: FrameInputCoalescer

        init(linkTicks: Bool = true) {
            let ledger = WakeupLedger()
            let stallClock = ManualClock()
            let time = MediaTime()
            let scheduler = FrameScheduler.testing(clock: stallClock, ledger: ledger, mediaTime: { time.now }) { _ -> (any FrameLink)? in
                if linkTicks { return CoalescerTestLink() }
                return PausedTestLink()
            }
            self.scheduler = scheduler
            self.stallClock = stallClock
            self.time = time
            fallbackClock = ManualClock()
            coalescer = FrameInputCoalescer(scheduler: scheduler, clock: fallbackClock, ledger: ledger)
        }

        /// One 120 Hz link frame.
        func tick(_ frame: Int) {
            scheduler.frameDidFire(timestamp: 1000 + Double(frame) / 120, refreshInterval: 1.0 / 120)
        }
    }

    private static func move(x: Int, at time: Double = 1) -> InputEventRecord {
        InputEventRecord(type: .mouseMoved, timestamp: time, windowNumber: 1, location: InputPoint(x: Double(x), y: 0))
    }

    private static func drag(x: Int, at time: Double = 1, modifiers: InputModifierFlags = []) -> InputEventRecord {
        InputEventRecord(type: .leftMouseDragged, timestamp: time, windowNumber: 1, location: InputPoint(x: Double(x), y: 0),
                         modifierFlags: modifiers)
    }

    private static func scroll(_ phase: InputScrollPhase, dy: Double) -> InputEventRecord {
        InputEventRecord(type: .scrollWheel, timestamp: 1, windowNumber: 1, scrollPhase: phase,
                         scrollDelta: InputPoint(x: 0, y: dy), hasPreciseScrollingDeltas: true)
    }

    private static func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}

@MainActor
private final class CoalescerTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

/// An occluded window's link: it never runs, whatever the clock asks.
@MainActor
private final class PausedTestLink: FrameLink {
    var isPaused: Bool {
        get { true }
        set {}
    }
    func invalidate() {}
}
