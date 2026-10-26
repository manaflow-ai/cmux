public import AppKit

/// Continuous input aligned to a window's frame, as Chromium's `MainThreadEventQueue`
/// (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`) does it:
///
/// - Continuous events of one owner and kind merge into one delivery per frame
///   (`DispatchRafAlignedInput`). The body gets the latest event, every event of the frame in
///   order (getCoalescedEvents) and the sum of their deltas, so nothing a drag or scroll moved
///   is lost.
/// - The deliveries run in the window's frame tick before its frame clients, so an autoscroll
///   or a spring of the same frame sees this frame's pointer.
/// - Discrete input flushes the pending work first (`ShouldFlushQueue`):
///   ``flushBeforeDiscreteInput()``.
/// - An owner can ask for unbuffered delivery until the pointer goes up
///   (`needs_low_latency_until_pointer_up_`): ``requestUnbufferedUntilPointerUp(owner:)``.
/// - When no tick comes, a one-frame fallback delivers (`raf_fallback_timer_`). It is armed only
///   while the link has not ticked since the coalescer started waiting for it, so a live link
///   costs no timer per frame.
///
/// ```swift
/// coalescer.post(.pointerMove, owner: "PointerHover", sample: FrameInputSample(event)) { latest, _, _ in
///     hover.place(at: latest.location)
/// }
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

    /// The frame-interval fallback when no tick told the display's rate yet.
    public static let defaultFrameInterval: Duration = .microseconds(16_667)

    /// Weak: a window's scheduler owns its coalescer (``FrameScheduler/input``).
    private weak var scheduler: FrameScheduler?
    private lazy var client = FrameClient(inputStageOf: scheduler ?? .app, owner: "FrameInputCoalescer") { [weak self] tick in
        self?.frameTick(tick) ?? false
    }
    private let fallback: DemandTimer
    /// Keys in the order of their first post this frame.
    private var order: [Key] = []
    private var pending: [Key: Pending] = [:]
    private var unbufferedOwners: Set<String> = []
    /// A real link frame came since the client last started waiting: the next one will come too.
    private var linkTicking = false
    private var frameInterval = FrameInputCoalescer.defaultFrameInterval
    /// Told when work becomes pending (true) and when none is left (false).
    var onPendingChange: (@MainActor (Bool) -> Void)?

    /// Deliveries made by the fallback because no frame came (debug and tests).
    public private(set) var fallbackFires = 0
    /// Frames that delivered pending work (debug and tests).
    public private(set) var frameFlushes = 0

    /// A coalescer on `scheduler` (a window's is ``FrameScheduler/input``). `clock` runs the fallback.
    public init(scheduler: FrameScheduler, clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared) {
        self.scheduler = scheduler
        fallback = DemandTimer(owner: "FrameInputCoalescer.fallback", clock: clock, ledger: ledger)
    }

    /// Work is waiting for the next frame.
    public var hasPending: Bool { !order.isEmpty }

    /// The one-frame fallback is armed (debug and tests: never while the link ticks).
    public var isFallbackArmed: Bool { fallback.isScheduled }

    /// Queues `sample` for `owner`'s next frame delivery of `kind`; `body` replaces the body of
    /// the earlier posts of this frame. For an unbuffered owner it runs at once, after that
    /// owner's pending work.
    public func post(_ kind: FrameInputKind, owner: String, sample: FrameInputSample, _ body: @escaping Body) {
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
            let wasEmpty = order.isEmpty
            order.append(key)
            pending[key] = Pending(samples: [sample], delta: sample.delta, body: body)
            if wasEmpty { onPendingChange?(true) }
        }
        if !client.isActive {
            linkTicking = false
            client.activate()
        }
        if !linkTicking, !fallback.isScheduled {
            fallback.schedule(after: frameInterval) { @MainActor [weak self] in self?.fallbackFired() }
        }
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

    /// Delivers every owner's pending work now, in first-post order: a discrete event is about to
    /// be dispatched, and its handlers must see the continuous input that came before it.
    public func flushBeforeDiscreteInput() {
        flushAll()
    }

    /// `owner`'s posts run at once, not at the frame, until ``pointerUp()``. Drags whose handler
    /// must follow every event (a resize handle, a drawing stroke) ask for it on mouseDown.
    public func requestUnbufferedUntilPointerUp(owner: String) {
        flush(owner: owner)
        unbufferedOwners.insert(owner)
    }

    /// The pointer went up: flushes the pending work and ends unbuffered delivery.
    public func pointerUp() {
        flushAll()
        unbufferedOwners.removeAll()
    }

    /// Drops the pending work and the fallback (the window closed: its scheduler calls this).
    public func invalidate() {
        let hadPending = !order.isEmpty
        order.removeAll()
        pending.removeAll()
        unbufferedOwners.removeAll()
        fallback.cancel()
        client.deactivate()
        if hadPending { onPendingChange?(false) }
    }

    // MARK: Delivery

    /// The frame tick: delivers, then ticks once more so input of the next frame finds the link
    /// running (and needs no fallback); an empty tick goes idle.
    private func frameTick(_ tick: FrameTick) -> Bool {
        // A synthesized (stalled) frame proves nothing about the link: the fallback stays armed.
        linkTicking = tick.refreshInterval != nil
        if linkTicking, fallback.isScheduled { fallback.cancel() }
        if let interval = tick.refreshInterval, interval > 0 { frameInterval = .seconds(interval) }
        guard !order.isEmpty else { return false }
        frameFlushes += 1
        flushAll()
        return true
    }

    private func fallbackFired() {
        guard !linkTicking, !order.isEmpty else { return }
        fallbackFires += 1
        flushAll()
    }

    /// Runs every pending delivery; posts made by the bodies wait for the next frame.
    private func flushAll() {
        guard !order.isEmpty else { return }
        let keys = order
        let entries = pending
        order.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        onPendingChange?(false)
        for key in keys { entries[key]?.run() }
    }

    private func flush(owner: String) {
        let keys = order.filter { $0.owner == owner }
        guard !keys.isEmpty else { return }
        let entries = keys.compactMap { pending.removeValue(forKey: $0) }
        order.removeAll { $0.owner == owner }
        if order.isEmpty { onPendingChange?(false) }
        for entry in entries { entry.run() }
    }
}
