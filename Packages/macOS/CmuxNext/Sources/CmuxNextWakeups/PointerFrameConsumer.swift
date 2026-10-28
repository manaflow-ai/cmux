public import CmuxNextInputCore

/// One consumer of a window's pointer input on its ``FrameInputCoalescer`` (a divider drag, a hover
/// tracker, a scroller), made by ``FrameInputCoalescer/consumer(owner:lowLatency:deliver:)``.
///
/// A frame interval runs from one frame tick to the next; a discrete event the coalescer flushes for,
/// and the consumer's own ``flush()``, also end it. In an interval the consumer gets its first event at
/// once (the leading edge) and then one delivery per run of mergeable input at the tick: two for a
/// steady drag, hover or scroll phase; one more for each change of kind, button, modifiers or scroll
/// phase in the interval (Chromium delivers such events apart too). A ``isLowLatency`` consumer gets
/// every event at once. Its owner keeps it for as long as it posts; ``cancel()`` drops what it has
/// pending.
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
public final class PointerFrameConsumer {
    /// Who consumes the pointer frames, in the wakeup ledger and the board.
    public let owner: String
    /// Every event is delivered at once, never merged (Chrome's `needs_low_latency_`).
    public let isLowLatency: Bool
    private weak var coalescer: FrameInputCoalescer?
    /// Gets each delivery and the frame it is drawn in (``FrameInputCoalescer/frameTime(for:)``).
    private let body: @MainActor (PointerCoalescedInput, PointerFrameTime) -> Void
    /// What waits for the frame; `spare` is the emptied queue a delivery swaps in, so input posted by
    /// a delivery's body goes to the live queue and no buffer is made per frame.
    private var queue = PointerCoalescingQueue()
    private var spare = PointerCoalescingQueue()
    private var deliveriesInInterval = 0

    /// The most deliveries it got in one frame interval (debug.input's `deliveries_per_frame`): 2 for
    /// one kind of input, one more per run of input that does not merge (see the type's comment); 0 for
    /// a low-latency consumer, which has no interval.
    public private(set) var maxDeliveriesPerFrame = 0
    /// Deliveries made (debug and tests).
    public private(set) var deliveries = 0

    /// It delivered in this interval: later input waits for the frame.
    var deliveredInInterval = false
    /// It is on its coalescer's list of consumers whose interval the next frame ends.
    var isInInterval = false

    init(owner: String, lowLatency: Bool, coalescer: FrameInputCoalescer,
         deliver: @escaping @MainActor (PointerCoalescedInput, PointerFrameTime) -> Void) {
        self.owner = owner
        isLowLatency = lowLatency
        self.coalescer = coalescer
        body = deliver
    }

    /// Posts a move, drag or scroll record; any other record is ignored, and so is every record once
    /// its window's scheduler is gone.
    public func post(_ record: InputEventRecord) {
        coalescer?.post(record, from: self)
    }

    /// Delivers its pending input now (a mouse-up ends the drag: the last point must land first).
    public func flush() {
        coalescer?.flush(self)
    }

    /// Drops its pending input; its next event is a leading edge again.
    public func cancel() {
        coalescer?.cancel(self)
    }

    /// Input of this consumer is waiting for the frame.
    public var hasPending: Bool { !queue.isEmpty }

    /// Emptied drag sample buffers it keeps for reuse (debug and tests: a steady drag allocates none).
    public var spareSampleBuffers: Int { queue.spareSampleBuffers + spare.spareSampleBuffers }

    // MARK: Coalescer

    var queueIsEmpty: Bool { queue.isEmpty }
    var queueHasDrag: Bool { queue.hasDrag }

    func enqueue(_ record: InputEventRecord) {
        queue.append(record)
    }

    /// Delivers `record` alone, its drag samples in a pooled buffer.
    func deliverAlone(_ record: InputEventRecord) {
        guard var input = queue.single(record) else { return }
        deliver(input)
        queue.recycle(&input)
    }

    /// Delivers every queued entry in order.
    func deliverPending() {
        guard !queue.isEmpty else { return }
        var due = PointerCoalescingQueue()
        swap(&due, &spare)
        swap(&due, &queue)
        due.drain { deliver($0) }
        spare = due
    }

    func dropPending() { queue.removeAll() }

    /// Its interval ended: the next input is a leading edge again.
    func endInterval() {
        deliveredInInterval = false
        isInInterval = false
        deliveriesInInterval = 0
    }

    private func deliver(_ input: PointerCoalescedInput) {
        deliveries += 1
        if !isLowLatency {
            deliveriesInInterval += 1
            maxDeliveriesPerFrame = max(maxDeliveriesPerFrame, deliveriesInInterval)
        }
        body(input, coalescer?.frameTime(for: input)
            ?? PointerFrameTime(time: input.latest.timestamp, interval: FrameTick.defaultRefreshInterval))
    }
}
