public import AppKit
public import CmuxNextInputCore
public import CmuxNextWakeups

/// A window's continuous pointer input (moves, drags, scrolls) delivered at most twice per display
/// frame per consumer and run of mergeable input, as Chromium's `MainThreadEventQueue` does it
/// (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`):
///
/// - Leading edge: the first event of a consumer in a frame interval is delivered at once, so a lone
///   move after an idle frame costs no wait. Later events of that interval merge
///   (``PointerCoalescingQueue``) and go out once at the window's frame tick (`DispatchRafAlignedInput`).
/// - Discrete input flushes what is pending first (`ShouldFlushQueue`): ``flushNow()``, which
///   ``flushBeforeDiscreteInput(on:window:)`` calls for every key, flags, button and gesture event.
/// - When no link frame comes (an occluded window, a stopped link) a one-shot fallback delivers
///   (`raf_fallback_timer_`): one refresh interval when a drag waits, ``idleFallbackDelay`` otherwise
///   (Chrome's `kMaxRafDelay`). It is armed only while entries are pending and the link is not
///   running, so a live link costs no timer per frame.
/// - A ``PointerFrameConsumer/isLowLatency`` consumer is never coalesced (`needs_low_latency_`).
///
/// Idle costs nothing: its frame client goes idle one frame after the last delivery, and no timer
/// is armed while nothing is pending.
///
/// ```swift
/// let drag = coalescer.consumer(owner: "DividerDrag") { [weak self] input in
///     for sample in input.samples { self?.velocity.add(sample) }
///     self?.applyDrag(at: input.latest.location)
/// }
/// override func mouseDragged(with event: NSEvent) { drag.post(event) }
/// override func mouseUp(with event: NSEvent) { drag.flush(); endDrag() }
/// ```
@MainActor
public final class PointerFrameCoalescer {
    /// How long pending moves and scrolls wait for a frame that does not come (Chrome's
    /// `kMaxRafDelay`, main_thread_event_queue.cc).
    public static let idleFallbackDelay: Duration = .seconds(5)
    /// A drag's fallback before the first link frame told the display's rate (60 Hz).
    public static let defaultFrameInterval: Duration = .microseconds(16_667)

    /// Weak: a closed window's scheduler goes away with the window; its coalescer does not keep it.
    private weak var scheduler: FrameScheduler?
    private lazy var client = FrameClient(owner: "PointerFrameCoalescer", isAnimation: false,
                                          on: scheduler ?? .app) { [weak self] tick in
        self?.frameTick(tick) ?? false
    }
    private let fallback: DemandTimer
    /// The armed fallback is the one-frame (drag) deadline, not the idle one.
    private var fallbackIsFrameDeadline = false
    /// Consumers with entries waiting, in the order their first entry came.
    private var pending: [PointerFrameConsumer] = []
    /// Consumers that delivered or queued since the last frame: the frame resets their interval.
    private var inInterval: [PointerFrameConsumer] = []
    /// A real link frame (not a stall tick) came since the client last started ticking.
    private var linkTicked = false
    private var frameInterval = PointerFrameCoalescer.defaultFrameInterval

    /// Frames (link or stall ticks) that delivered pending input (debug and tests).
    public private(set) var frameDeliveries = 0
    /// Deliveries made by the fallback because no frame came (debug and tests).
    public private(set) var fallbackFires = 0

    /// A coalescer on `scheduler` (a window's ``FrameScheduler/forWindow(_:)``). `fallback` is its own
    /// one-shot timer: the composition root makes it with the app's `mainWork`, tests with a manual clock.
    public init(scheduler: FrameScheduler, fallback: DemandTimer) {
        self.scheduler = scheduler
        self.fallback = fallback
    }

    /// A consumer of this window's pointer input; `deliver` runs once per delivery. A `lowLatency`
    /// consumer gets every event at once, never merged.
    public func consumer(owner: String, lowLatency: Bool = false,
                         deliver: @escaping @MainActor (PointerCoalescedInput) -> Void) -> PointerFrameConsumer {
        PointerFrameConsumer(owner: owner, lowLatency: lowLatency, coalescer: self, deliver: deliver)
    }

    /// Input is waiting for the next frame.
    public var hasPending: Bool { !pending.isEmpty }

    /// The frame client is ticking (debug and tests: false while idle).
    public var isTicking: Bool { client.isActive }

    /// The fallback timer is armed (debug and tests: never while idle or while the link ticks).
    public var isFallbackArmed: Bool { fallback.isScheduled }

    /// Delivers every consumer's pending input now, in the order it came: a discrete event is about
    /// to be dispatched, and its handlers must see the continuous input before it (`ShouldFlushQueue`).
    public func flushNow() {
        guard !pending.isEmpty else { return }
        let due = pending
        pending.removeAll(keepingCapacity: true)
        cancelFallbackIfIdle()
        for consumer in due { consumer.deliverPending() }
    }

    /// Flushes this window's pending input before each key, flags, button and gesture event the tap
    /// dispatches. An observer, not an intercept: observers run before the key router, so a shortcut
    /// the router consumes still sees the moves before it. Keep the returned subscription.
    public func flushBeforeDiscreteInput(on tap: InputEventTap,
                                         window: InputEventTap.WindowScope) -> InputSubscription {
        tap.subscribe(class: [.key, .flags, .button, .gesture], phase: .observe, window: window,
                      while: { [weak self] in self?.hasPending ?? false }) { [weak self] _ in
            self?.flushNow()
        }
    }

    /// Drops every pending entry, the fallback and the frame client (the window closed).
    public func invalidate() {
        for consumer in pending { consumer.dropPending() }
        pending.removeAll()
        for consumer in inInterval { consumer.endInterval() }
        inInterval.removeAll()
        fallback.cancel()
        client.deactivate()
    }

    // MARK: Consumers

    /// `consumer` got `record`: delivered at once on its interval's leading edge, queued otherwise.
    func post(_ record: InputEventRecord, from consumer: PointerFrameConsumer) {
        if consumer.isLowLatency {
            guard let input = PointerCoalescedInput(record) else { return }
            return consumer.deliver(input)
        }
        if consumer.queueIsEmpty, !consumer.deliveredInInterval {
            guard let input = PointerCoalescedInput(record) else { return }
            consumer.deliveredInInterval = true
            enterInterval(consumer)
            keepTicking()
            return consumer.deliver(input)
        }
        let wasEmpty = consumer.queueIsEmpty
        guard consumer.enqueue(record) else { return }
        if wasEmpty { pending.append(consumer) }
        enterInterval(consumer)
        keepTicking()
        armFallbackIfNeeded()
    }

    /// `consumer` delivers its pending input now (its pointer went up).
    func flush(_ consumer: PointerFrameConsumer) {
        guard let index = pending.firstIndex(where: { $0 === consumer }) else { return }
        pending.remove(at: index)
        cancelFallbackIfIdle()
        consumer.deliverPending()
    }

    /// `consumer` stopped: its pending input is dropped.
    func cancel(_ consumer: PointerFrameConsumer) {
        consumer.dropPending()
        pending.removeAll { $0 === consumer }
        inInterval.removeAll { $0 === consumer }
        consumer.endInterval()
        cancelFallbackIfIdle()
    }

    // MARK: Frames

    private func enterInterval(_ consumer: PointerFrameConsumer) {
        guard !consumer.isInInterval else { return }
        consumer.isInInterval = true
        inInterval.append(consumer)
    }

    private func keepTicking() {
        guard !client.isActive else { return }
        linkTicked = false
        client.activate()
    }

    /// The link runs and has ticked this window since the client started: the next frame will come.
    private var linkRunning: Bool {
        guard let scheduler else { return false }
        return linkTicked && scheduler.isRunning && !scheduler.ticksOffLink
    }

    private func armFallbackIfNeeded() {
        guard !pending.isEmpty, !linkRunning else { return }
        let frameDeadline = pending.contains { $0.queueHasDrag }
        if fallback.isScheduled, fallbackIsFrameDeadline || !frameDeadline { return }
        fallbackIsFrameDeadline = frameDeadline
        fallback.scheduleOnMain(after: frameDeadline ? frameInterval : Self.idleFallbackDelay) { [weak self] in
            self?.fallbackFired()
        }
    }

    private func cancelFallbackIfIdle() {
        guard pending.isEmpty, fallback.isScheduled else { return }
        fallback.cancel()
    }

    /// The window's frame: delivers the trailing input and starts a new interval. It keeps ticking while
    /// this interval had input, so the next interval's input finds the link running (no fallback); a
    /// frame after an interval with none goes idle.
    private func frameTick(_ tick: FrameTick) -> Bool {
        linkTicked = tick.refreshInterval != nil && scheduler?.ticksOffLink == false
        if let interval = tick.refreshInterval, interval > 0 { frameInterval = .seconds(interval) }
        if linkTicked, fallback.isScheduled { fallback.cancel() }
        let hadInput = !inInterval.isEmpty
        if !pending.isEmpty { frameDeliveries += 1 }
        deliverFrame()
        return hadInput || !inInterval.isEmpty
    }

    private func fallbackFired() {
        guard !pending.isEmpty else { return }
        fallbackFires += 1
        deliverFrame()
        armFallbackIfNeeded()
    }

    /// Delivers every pending consumer's input, then ends the interval. Input the deliveries post
    /// waits for the next frame.
    private func deliverFrame() {
        let due = pending
        let ending = inInterval
        pending.removeAll(keepingCapacity: true)
        inInterval.removeAll(keepingCapacity: true)
        for consumer in due {
            consumer.deliveredInInterval = true
            consumer.deliverPending()
        }
        // Every queued consumer is in the ending interval, so the trailing delivery counts there.
        for consumer in ending { consumer.endInterval() }
        // Input those deliveries posted waits for the next frame: its consumers are in the new interval.
        for consumer in pending { enterInterval(consumer) }
        cancelFallbackIfIdle()
    }
}

/// One consumer of a window's ``PointerFrameCoalescer``: a divider drag, a hover tracker, a scroller.
/// Per frame interval it gets the leading event and one trailing delivery per run of mergeable
/// input (two for a steady drag, hover or scroll phase) unless it is ``isLowLatency``. ``cancel()``
/// drops what it has pending; its owner keeps it for as long as it posts.
@MainActor
public final class PointerFrameConsumer {
    public let owner: String
    /// Every event is delivered at once, never merged (Chrome's `needs_low_latency_`).
    public let isLowLatency: Bool
    private weak var coalescer: PointerFrameCoalescer?
    private let body: @MainActor (PointerCoalescedInput) -> Void
    private var queue = PointerCoalescingQueue()
    private var deliveriesInInterval = 0

    /// The most deliveries it got in one frame interval (debug.input's `deliveries_per_frame`; at most
    /// 2 unless low latency).
    public private(set) var maxDeliveriesPerFrame = 0
    /// Deliveries made (debug and tests).
    public private(set) var deliveries = 0

    /// It delivered in this frame interval: later input waits for the frame.
    var deliveredInInterval = false
    /// It is on its coalescer's list of consumers the next frame ends an interval for.
    var isInInterval = false

    init(owner: String, lowLatency: Bool, coalescer: PointerFrameCoalescer,
         deliver: @escaping @MainActor (PointerCoalescedInput) -> Void) {
        self.owner = owner
        isLowLatency = lowLatency
        self.coalescer = coalescer
        body = deliver
    }

    /// Posts a move, drag or scroll; false (nothing posted) for any other event type.
    @discardableResult
    public func post(_ event: NSEvent) -> Bool {
        guard let type = InputEventType(event.type), PointerCoalescedKind(type) != nil else { return false }
        post(InputEventRecord(event, type: type))
        return true
    }

    /// Posts a move, drag or scroll record; any other record is ignored.
    public func post(_ record: InputEventRecord) {
        coalescer?.post(record, from: self)
    }

    /// Delivers its pending input now (a mouse-up ends the drag: the last point must land first).
    public func flush() {
        coalescer?.flush(self)
    }

    /// Drops its pending input and stops its deliveries until the next post.
    public func cancel() {
        coalescer?.cancel(self)
    }

    /// Input of this consumer is waiting for the frame.
    public var hasPending: Bool { !queue.isEmpty }

    // MARK: Coalescer

    var queueIsEmpty: Bool { queue.isEmpty }
    var queueHasDrag: Bool { queue.hasDrag }

    func enqueue(_ record: InputEventRecord) -> Bool { queue.append(record) }

    func deliver(_ input: PointerCoalescedInput) {
        deliveries += 1
        deliveriesInInterval += 1
        maxDeliveriesPerFrame = max(maxDeliveriesPerFrame, deliveriesInInterval)
        body(input)
    }

    func deliverPending() {
        for input in queue.drain() { deliver(input) }
    }

    func dropPending() { queue.removeAll() }

    /// A frame ended its interval: the next input is a leading edge again.
    func endInterval() {
        deliveredInInterval = false
        isInInterval = false
        deliveriesInInterval = 0
    }
}
