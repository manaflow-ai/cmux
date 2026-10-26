import AppKit
import CmuxNextInput
import CmuxNextInputCore
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A window's pointer input once per frame (p04-input-030; Chromium's main_thread_event_queue.cc):
/// leading edge at once, one merged trailing delivery at the tick, discrete input flushes first, the
/// fallback delivers when the link does not tick, and an idle window holds no client, link or timer.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct PointerFrameCoalescerTests {
    /// What deliveries a consumer got: a class, so `@MainActor` bodies share it without a captured `var`.
    final class Log {
        var inputs: [PointerCoalescedInput] = []
        var events: [String] = []
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

    /// A steady drag across frames never gets more than two deliveries in a frame interval, and a
    /// ticking link arms no fallback.
    @Test func aSteadyDragStaysAtTwoDeliveriesPerFrameWithNoFallback() {
        let rig = Rig()
        let log = Log()
        let consumer = rig.coalescer.consumer(owner: "divider") { log.inputs.append($0) }
        var x = 0
        for frame in 1...6 {
            for _ in 0..<5 {
                consumer.post(Self.drag(x: x))
                x += 1
            }
            if frame > 1 { #expect(!rig.coalescer.isFallbackArmed, "the link ticks: no timer") }
            rig.tick(frame)
        }
        #expect(consumer.maxDeliveriesPerFrame == 2)
        #expect(log.inputs.count == 12)
        #expect(log.inputs.reduce(0) { $0 + $1.coalescedCount } == 30, "every event is in some delivery")
        #expect(rig.coalescer.fallbackFires == 0)
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

    /// The trailing delivery runs in the window's input stage, before the frame's springs and drivers,
    /// and a client it wakes ticks in the same frame (p04-input-032; Blink dispatches rAF-aligned input
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

    /// A button flushes the pending moves before its handlers run (ShouldFlushQueue), through the tap.
    @Test func aButtonFlushesPendingMovesFirst() throws {
        _ = NSApplication.shared
        let rig = Rig()
        let tap = InputEventTap()
        let log = Log()
        let hover = rig.coalescer.consumer(owner: "hover") { input in
            log.events.append("move \(Int(input.latest.location.x)) x\(input.coalescedCount)")
        }
        let flush = rig.coalescer.flushBeforeDiscreteInput(on: tap, window: .anyWindow)
        let button = tap.subscribe(class: .button) { _ in log.events.append("button") }
        for index in 0..<3 { hover.post(Self.move(x: index)) }
        #expect(log.events == ["move 0 x1"])

        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        tap.dispatching { tap.deliverObserve(down) }
        #expect(log.events == ["move 0 x1", "move 2 x2", "button"])
        #expect(!rig.coalescer.hasPending)
        rig.tick(1)
        #expect(log.events.count == 3, "the flushed moves do not run again at the frame")
        withExtendedLifetime((flush, button)) {}
        rig.coalescer.invalidate()
    }

    /// flushNow runs every consumer's pending input in the order it came; a consumer's own flush
    /// (its mouse-up) runs only its own.
    @Test func flushesRunPendingInputInArrivalOrder() {
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
        rig.coalescer.flushNow()
        #expect(log.events == ["a", "b", "a"])
        #expect(!rig.coalescer.hasPending)
        rig.coalescer.invalidate()
    }

    // MARK: Fallback

    /// An occluded window's link does not tick: a pending drag still goes out one refresh interval
    /// later through the fallback, and no timer stays armed after it.
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
        #expect(rig.fallbackClock.sleepRequests.last?.deadline.offset == PointerFrameCoalescer.defaultFrameInterval,
                "a drag waits one refresh interval")
        rig.fallbackClock.advance(by: PointerFrameCoalescer.defaultFrameInterval)
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
        #expect(rig.fallbackClock.sleepRequests.last?.deadline.offset == PointerFrameCoalescer.idleFallbackDelay)
        consumer.flush()
        #expect(!rig.coalescer.isFallbackArmed, "nothing pending: the fallback is cancelled")
        #expect(log.inputs.count == 2)
        rig.coalescer.invalidate()
    }

    // MARK: Support

    /// A window scheduler on a fake link that ticks only when the test says (`linkTicks`), or stays
    /// paused as an occluded window's does; its stall clock never moves, so every frame is the test's.
    @MainActor
    struct Rig {
        let scheduler: FrameScheduler
        let fallbackClock: ManualClock
        let coalescer: PointerFrameCoalescer

        init(linkTicks: Bool = true) {
            let ledger = WakeupLedger()
            let clock = ManualClock()
            let scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: ledger, mediaTime: { 1000 }) { _ -> (any FrameLink)? in
                if linkTicks { return CoalescerTestLink() }
                return PausedTestLink()
            }
            self.scheduler = scheduler
            fallbackClock = clock
            coalescer = PointerFrameCoalescer(
                scheduler: scheduler,
                fallback: DemandTimer(owner: "PointerFrameCoalescer.fallback", clock: clock, ledger: ledger))
        }

        /// One 120 Hz link frame.
        func tick(_ frame: Int) {
            scheduler.frameDidFire(timestamp: 1000 + Double(frame) / 120, refreshInterval: 1.0 / 120)
        }
    }

    private static func move(x: Int, at time: Double = 1) -> InputEventRecord {
        InputEventRecord(type: .mouseMoved, timestamp: time, windowNumber: 1, location: InputPoint(x: Double(x), y: 0))
    }

    private static func drag(x: Int, at time: Double = 1) -> InputEventRecord {
        InputEventRecord(type: .leftMouseDragged, timestamp: time, windowNumber: 1, location: InputPoint(x: Double(x), y: 0))
    }

    private static func scroll(_ phase: InputScrollPhase, dy: Double) -> InputEventRecord {
        InputEventRecord(type: .scrollWheel, timestamp: 1, windowNumber: 1, scrollPhase: phase,
                         scrollDelta: InputPoint(x: 0, y: dy), hasPreciseScrollingDeltas: true)
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
