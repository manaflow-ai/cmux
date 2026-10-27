public import AppKit
public import CmuxNextInputCore

/// A window's continuous input aligned to its frame, as Chromium's `MainThreadEventQueue`
/// (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`) does it. It is the
/// window's one coalescer (``FrameScheduler/input``), with one input-stage client, one fallback timer
/// and one pending list in arrival order, so a flush delivers every poster's input in the order it came.
///
/// Two kinds of poster share it:
///
/// - ``post(_:owner:sample:_:)``: one body per owner and kind per frame (`DispatchRafAlignedInput`).
///   The body gets the latest event, every event of the frame in order (getCoalescedEvents) and the
///   sum of their deltas, so nothing a drag or scroll moved is lost.
/// - ``consumer(owner:lowLatency:deliver:)``: a ``PointerFrameConsumer`` of ``InputEventRecord``s with
///   a leading edge (its first event of a frame interval goes out at once) and Chromium's merge rules
///   (``PointerCoalescingQueue``); the rest of the interval goes out once at the frame tick.
///
/// For both:
///
/// - The deliveries run in the window's frame tick before its frame clients (the scheduler's input
///   stage), so an autoscroll or a spring of the same frame sees this frame's pointer.
/// - Discrete input flushes the pending work first (`ShouldFlushQueue`): `sendEvent` calls
///   ``FrameInputCoalescers/willDispatch(_:)`` before any tap observer runs.
/// - When no frame comes, a one-shot fallback delivers (`raf_fallback_timer_`): one refresh interval
///   while a keyed post or a drag waits, ``idleFallbackDelay`` otherwise (Chrome's `kMaxRafDelay`). It
///   is armed only while work is pending and the window's link is not running, so a live link costs
///   no timer.
/// - Its window closing drops its work, its fallback and its client (``invalidate()``). A post after
///   its scheduler is gone is dropped; it never ticks on another scheduler.
///
/// ```swift
/// coalescer.post(.pointerMove, owner: "PointerHover", sample: FrameInputSample(event)) { latest, _, _ in
///     hover.place(at: latest.location)
/// }
/// let drag = coalescer.consumer(owner: "DividerDrag") { input in apply(input.latest.location) }
/// ```
@MainActor
public final class FrameInputCoalescer {
    /// Runs once per frame for an owner and kind: the latest event, the frame's events in post
    /// order (the latest last) and the sum of their deltas.
    public typealias Body = @MainActor (_ latest: FrameInputSample, _ coalesced: [FrameInputSample], _ delta: CGVector) -> Void

    private struct Key: Hashable {
        let owner: String
        let kind: FrameInputKind
    }

    private struct Pending {
        var samples: [FrameInputSample]
        var delta: CGVector
        /// The latest post's body: it captured the latest state.
        var body: Body

        @MainActor func run() {
            guard let latest = samples.last else { return }
            body(latest, samples, delta)
        }
    }

    /// One waiting delivery, in arrival order across both kinds of poster.
    private enum Slot {
        case keyed(Key)
        case consumer(PointerFrameConsumer)
    }

    /// The frame-interval fallback when no tick told the display's rate yet.
    public static let defaultFrameInterval: Duration = .microseconds(16_667)
    /// How long consumer moves and scrolls wait for a frame that does not come (Chrome's
    /// `kMaxRafDelay`, main_thread_event_queue.cc).
    public static let idleFallbackDelay: Duration = .seconds(5)

    /// Weak: a window's scheduler owns its coalescer (``FrameScheduler/input``).
    private weak var scheduler: FrameScheduler?
    private lazy var client = FrameClient(inputStageOf: scheduler ?? .app, owner: "FrameInputCoalescer") { [weak self] tick in
        self?.frameTick(tick) ?? false
    }
    private let fallback: DemandTimer
    /// The fallback is armed (kept here: reading the timer's state takes its lock).
    private var fallbackArmed = false
    /// The armed fallback is the one-frame deadline, not the idle one.
    private var fallbackIsFrameDeadline = false
    /// What waits for the frame, in arrival order; `spareOrder` is the other buffer a flush swaps in.
    private var order: [Slot] = []
    private var spareOrder: [Slot] = []
    private var pending: [Key: Pending] = [:]
    private var sparePending: [Key: Pending] = [:]
    private var unbufferedOwners: Set<String> = []
    /// Consumers that delivered or queued in this frame interval: the next frame ends their interval.
    private var inInterval: [PointerFrameConsumer] = []
    private var spareInterval: [PointerFrameConsumer] = []
    private var frameInterval = FrameInputCoalescer.defaultFrameInterval
    /// ``frameInterval`` in seconds, for ``frameTime(for:)``.
    private(set) var frameIntervalSeconds = FrameTick.defaultRefreshInterval
    /// The time of the frame tick whose deliveries run now; nil outside a tick.
    private(set) var tickTime: CFTimeInterval?
    /// Told when work becomes pending (true) and when none is left (false).
    var onPendingChange: (@MainActor (Bool) -> Void)?

    /// Deliveries made by the fallback because no frame came (debug and tests).
    public private(set) var fallbackFires = 0
    /// Frames that delivered pending work (debug and tests).
    public private(set) var frameFlushes = 0

    /// A coalescer on `scheduler` (a window's is ``FrameScheduler/input``). `clock` runs the fallback.
    public init(scheduler: FrameScheduler, clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared) {
        self.scheduler = scheduler
        // Precise: a one-frame deadline that took the 8 ms wake leeway would wait two or three frames.
        fallback = DemandTimer(owner: "FrameInputCoalescer.fallback", policy: .precise, clock: clock, ledger: ledger)
    }

    /// Work is waiting for the next frame.
    public var hasPending: Bool { !order.isEmpty }

    /// The fallback is armed (debug and tests: never while idle or while the link runs).
    public var isFallbackArmed: Bool { fallbackArmed }

    /// The input-stage client is ticking (debug and tests: false while idle).
    public var isTicking: Bool { client.isActive }

    /// A consumer of this window's pointer input; `deliver` runs once per delivery. A `lowLatency`
    /// consumer gets every event at once, never merged (Chrome's `needs_low_latency_`).
    public func consumer(owner: String, lowLatency: Bool = false,
                         deliver: @escaping @MainActor (PointerCoalescedInput) -> Void) -> PointerFrameConsumer {
        PointerFrameConsumer(owner: owner, lowLatency: lowLatency, coalescer: self) { input, _ in deliver(input) }
    }

    /// Queues `sample` for `owner`'s next frame delivery of `kind`; `body` replaces the body of
    /// the earlier posts of this frame. For an unbuffered owner it runs at once, after that
    /// owner's pending work.
    public func post(_ kind: FrameInputKind, owner: String, sample: FrameInputSample, _ body: @escaping Body) {
        guard scheduler != nil else { return }
        if unbufferedOwners.contains(owner) {
            flush(owner: owner)
            body(sample, [sample], sample.delta)
            return
        }
        let key = Key(owner: owner, kind: kind)
        if var entry = pending[key] {
            entry.samples.append(sample)
            entry.delta = CGVector(dx: entry.delta.dx + sample.delta.dx, dy: entry.delta.dy + sample.delta.dy)
            entry.body = body
            pending[key] = entry
        } else {
            pending[key] = Pending(samples: [sample], delta: sample.delta, body: body)
            append(.keyed(key))
        }
        keepTicking()
        armFallbackIfNeeded(frameDeadline: true)
    }

    /// Queues `event` when it is continuous; runs `body` at once, after the pending work, when it
    /// is not.
    public func post(_ event: NSEvent, owner: String, _ body: @escaping Body) {
        let sample = FrameInputSample(event)
        guard let kind = FrameInputKind(event.type) else {
            flushBeforeDiscreteInput()
            return body(sample, [sample], sample.delta)
        }
        post(kind, owner: owner, sample: sample, body)
    }

    /// Delivers every poster's pending work now, in arrival order: a discrete event is about to be
    /// dispatched, and its handlers must see the continuous input that came before it. The flushed
    /// consumers start a new interval, so their next event goes out at once.
    public func flushBeforeDiscreteInput() {
        flushAll(endingIntervals: false)
    }

    /// `owner`'s posts run at once, not at the frame, until ``pointerUp()``. Drags whose handler
    /// must follow every event (a resize handle, a drawing stroke) ask for it on mouseDown.
    public func requestUnbufferedUntilPointerUp(owner: String) {
        flush(owner: owner)
        unbufferedOwners.insert(owner)
    }

    /// The pointer went up: flushes the pending work and ends unbuffered delivery.
    public func pointerUp() {
        flushAll(endingIntervals: false)
        unbufferedOwners.removeAll()
    }

    /// Drops the pending work, the fallback and the client (the window closed: its scheduler calls
    /// this). A window shown again posts to the same coalescer, on the same scheduler.
    public func invalidate() {
        let hadPending = !order.isEmpty
        for case .consumer(let consumer) in order { consumer.dropPending() }
        order.removeAll()
        pending.removeAll()
        unbufferedOwners.removeAll()
        for consumer in inInterval { consumer.endInterval() }
        inInterval.removeAll()
        cancelFallback()
        client.deactivate()
        if hadPending { onPendingChange?(false) }
    }

    // MARK: Consumers

    /// `consumer` got `record`: delivered at once on its interval's leading edge (or always, when it is
    /// low latency), queued for the frame otherwise.
    func post(_ record: InputEventRecord, from consumer: PointerFrameConsumer) { // perf-hot: 2us pointer-coalesce (every continuous pointer event a consumer posts)
        guard scheduler != nil, let kind = PointerCoalescedKind(record.type) else { return }
        if consumer.isLowLatency { return consumer.deliverAlone(record) }
        if consumer.queueIsEmpty, !consumer.deliveredInInterval {
            consumer.deliveredInInterval = true
            enterInterval(consumer)
            keepTicking()
            return consumer.deliverAlone(record)
        }
        let wasEmpty = consumer.queueIsEmpty
        consumer.enqueue(record)
        if wasEmpty { append(.consumer(consumer)) }
        enterInterval(consumer)
        keepTicking()
        armFallbackIfNeeded(frameDeadline: kind == .drag)
    }

    /// `consumer` delivers its pending input now (its pointer went up) and starts a new interval.
    func flush(_ consumer: PointerFrameConsumer) {
        guard removeSlot(of: consumer) else { return }
        deliverQueued(consumer)
        endInterval(of: consumer)
    }

    /// `consumer` stopped: its pending input is dropped and its interval ends.
    func cancel(_ consumer: PointerFrameConsumer) {
        consumer.dropPending()
        _ = removeSlot(of: consumer)
        endInterval(of: consumer)
    }

    // MARK: Frames

    /// The frame tick: delivers, then ends the interval. It keeps ticking one frame past an interval
    /// with input, so the next interval's input finds the link running (and needs no fallback); a
    /// frame after an interval with none goes idle.
    private func frameTick(_ tick: FrameTick) -> Bool { // perf-hot: 0.1ms frame-tick (a window's input stage, every frame while input comes)
        if let interval = tick.refreshInterval, interval > 0 {
            frameInterval = .seconds(interval)
            frameIntervalSeconds = interval
        }
        if fallbackArmed, linkRunning { cancelFallback() }
        let hadInput = !order.isEmpty || !inInterval.isEmpty
        if !order.isEmpty { frameFlushes += 1 }
        tickTime = tick.timestamp
        flushAll(endingIntervals: true)
        tickTime = nil
        return hadInput || !order.isEmpty
    }

    private func fallbackFired() {
        fallbackArmed = false
        guard !order.isEmpty else { return }
        fallbackFires += 1
        flushAll(endingIntervals: true)
        // Posts the deliveries made wait for a frame or the next fallback.
        armFallbackIfNeeded(frameDeadline: pendingNeedsFrameDeadline)
    }

    /// A keyed post or a drag waits: its fallback is one frame, not the idle delay.
    private var pendingNeedsFrameDeadline: Bool {
        order.contains { slot in
            if case .consumer(let consumer) = slot { return consumer.queueHasDrag }
            return true
        }
    }

    /// Runs every pending delivery in arrival order; posts made by the bodies wait for the next frame.
    /// `endingIntervals`: a frame (or its fallback) ends every consumer's interval; a discrete flush
    /// ends only the intervals of the consumers it delivered.
    // perf-hot: 10us input-coalesce
    private func flushAll(endingIntervals: Bool) {
        if !order.isEmpty {
            var due: [Slot] = []
            swap(&due, &spareOrder)
            swap(&due, &order)
            var entries: [Key: Pending] = [:]
            swap(&entries, &sparePending)
            swap(&entries, &pending)
            cancelFallback()
            onPendingChange?(false)
            for slot in due {
                switch slot {
                case .keyed(let key): entries[key]?.run()
                case .consumer(let consumer):
                    deliverQueued(consumer)
                    if !endingIntervals { endInterval(of: consumer) }
                }
            }
            due.removeAll(keepingCapacity: true)
            spareOrder = due
            entries.removeAll(keepingCapacity: true)
            sparePending = entries
        }
        if endingIntervals { endIntervals() }
    }

    private func flush(owner: String) {
        let keys = order.compactMap { slot -> Key? in
            guard case .keyed(let key) = slot, key.owner == owner else { return nil }
            return key
        }
        guard !keys.isEmpty else { return }
        let entries = keys.compactMap { pending.removeValue(forKey: $0) }
        order.removeAll { slot in
            guard case .keyed(let key) = slot else { return false }
            return key.owner == owner
        }
        becameIdleIfEmpty()
        for entry in entries { entry.run() }
    }

    // MARK: State

    /// The window's link runs and ticks it (not the stall deadline): its next frame will come.
    private var linkRunning: Bool {
        guard let scheduler else { return false }
        return scheduler.isRunning && !scheduler.ticksOffLink
    }

    private func append(_ slot: Slot) {
        let wasEmpty = order.isEmpty
        order.append(slot)
        if wasEmpty { onPendingChange?(true) }
    }

    /// Removes `consumer`'s slot; false when it had none.
    private func removeSlot(of consumer: PointerFrameConsumer) -> Bool {
        let index = order.firstIndex { slot in
            guard case .consumer(let queued) = slot else { return false }
            return queued === consumer
        }
        guard let index else { return false }
        order.remove(at: index)
        becameIdleIfEmpty()
        return true
    }

    private func becameIdleIfEmpty() {
        guard order.isEmpty else { return }
        cancelFallback()
        onPendingChange?(false)
    }

    private func keepTicking() {
        guard !client.isActive else { return }
        client.activate()
    }

    /// Delivers `consumer`'s queued input as a delivery of this interval: input its body posts waits.
    private func deliverQueued(_ consumer: PointerFrameConsumer) {
        consumer.deliveredInInterval = true
        enterInterval(consumer)
        consumer.deliverPending()
    }

    private func enterInterval(_ consumer: PointerFrameConsumer) {
        guard !consumer.isInInterval else { return }
        consumer.isInInterval = true
        inInterval.append(consumer)
    }

    private func endInterval(of consumer: PointerFrameConsumer) {
        guard consumer.isInInterval else { return }
        consumer.endInterval()
        inInterval.removeAll { $0 === consumer }
    }

    /// Ends every consumer's interval (a frame): the next event of each is a leading edge again.
    private func endIntervals() {
        guard !inInterval.isEmpty else { return }
        var ending: [PointerFrameConsumer] = []
        swap(&ending, &spareInterval)
        swap(&ending, &inInterval)
        for consumer in ending { consumer.endInterval() }
        ending.removeAll(keepingCapacity: true)
        spareInterval = ending
    }

    /// Arms the fallback while work waits and the link does not run; `frameDeadline` (a keyed post or
    /// a drag) turns an armed idle deadline into a one-frame one.
    private func armFallbackIfNeeded(frameDeadline: Bool) {
        if fallbackArmed, fallbackIsFrameDeadline || !frameDeadline { return }
        guard !order.isEmpty, !linkRunning else { return }
        fallbackArmed = true
        fallbackIsFrameDeadline = frameDeadline
        fallback.scheduleOnMain(after: frameDeadline ? frameInterval : Self.idleFallbackDelay) { [weak self] in
            self?.fallbackFired()
        }
    }

    private func cancelFallback() {
        guard fallbackArmed else { return }
        fallbackArmed = false
        fallback.cancel()
    }
}
