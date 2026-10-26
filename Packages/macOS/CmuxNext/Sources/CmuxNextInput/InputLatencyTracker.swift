public import AppKit
public import CmuxNextInputCore
public import CmuxNextSignposts
import Darwin

/// EventLatency for cmux: each tracked input event's stages, from its OS timestamp to the frame that shows it
/// (plans/cmux-next/chrome-parity/p04-input.md, section 3 (I), task 004).
///
/// Chrome keeps one `EventMetrics` per event (cc/metrics/event_metrics.h) and closes it at the presentation feedback
/// of the frame that shows it (cc/metrics/compositor_frame_reporter.cc). Here:
/// - ``begin(event:kind:target:entrypoint:)`` opens a slot in the lock-free ``InputLatencySlotTable``, stamps
///   `generated` (the event's OS time), `arrivedMain` and `dispatchStart`, and keeps the window's display link for a
///   few frames (``InputPresentationEstimating/holdLinkForInput(in:)``) so the commit reads a real vsync.
/// - ``mark(_:_:at:)`` stamps any other stage from any thread, once (a terminal writer, a text input helper).
/// - ``endDispatch(_:)`` stamps `dispatchEnd` after the app's dispatch returned.
/// - After the Core Animation commit that ends the turn (``CommitBoundary``, one boundary per turn, asked for when
///   the turn's first slot opens), every slot opened in the turn gets `mainCommit` and an estimated `presented`
///   (the commit's vsync plus one render-server frame, ``InputPresentationEstimating``), closes, goes into the
///   single-writer ``InputLatencyRing`` and is recorded as one ``SignpostName/inputLatency`` event. A slot whose
///   dispatch ran a nested run loop closes at that loop's first commit, the frame that showed its response, with
///   `dispatchEnd` skipped. A missed commit (``CommitBoundary/Outcome/missed``) closes with `mainCommit` and
///   `presented` skipped, so readers drop it instead of counting idle time.
/// - Every half ring goes to the batch sink (the ledger, p04-input-002) as one array.
///
/// The per-event path makes no allocation, takes no lock, builds no `String` and makes no system call besides the
/// clock read: the pending list is reserved at init, the commit closure is built once, and the signpost is typed
/// numbers the log system formats only when something reads them.
///
/// ```swift
/// let tracker = InputLatencyTracker(presentation: presentationClock)
/// let token = tracker.begin(event: event, kind: .keyPress, target: .terminal, entrypoint: .person)
/// super.sendEvent(event)
/// if let token { tracker.endDispatch(token) }
/// ```
public final class InputLatencyTracker {
    /// Asks for the turn's commit boundary (``CommitBoundary/after(_:)``; tests fire it themselves).
    public typealias AfterCommit = @MainActor (@escaping @MainActor (CommitBoundary.Outcome) -> Void) -> Void
    /// Records one closed slot (the `input.latency` signpost and trace point; tests count).
    public typealias Emit = @MainActor (InputLatencySlot) -> Void
    /// Takes one batch of closed slots, oldest first (the ledger).
    public typealias BatchSink = @MainActor ([InputLatencySlot]) -> Void

    /// One slot opened this turn, waiting for the turn's commit.
    private struct Pending {
        let token: InputLatencyToken
        let window: NSWindow?
    }

    /// The open slots: any thread stamps stages here through ``mark(_:_:at:)``.
    public nonisolated let table: InputLatencySlotTable
    /// `CLOCK_UPTIME_RAW` nanoseconds now.
    private nonisolated let now: @Sendable () -> UInt64
    private let ring: InputLatencyRing
    private let presentation: any InputPresentationEstimating
    private let afterCommit: AfterCommit
    private let emit: Emit
    private let batchSink: BatchSink?
    /// Slots opened since the last boundary; reserved to the table's capacity, so appends never allocate.
    private var pending: ContiguousArray<Pending> = []
    /// The boundary closure, built once so asking for a boundary allocates nothing here.
    private lazy var closeAtCommit: @MainActor (CommitBoundary.Outcome) -> Void = { [weak self] in self?.closePending($0) }

    /// Slots closed since launch.
    public private(set) var closedCount: UInt64 = 0

    /// A tracker on the app's commit boundary, an `input` signposter and `CLOCK_UPTIME_RAW`.
    ///
    /// - Parameters:
    ///   - presentation: The presented-time estimate (the app's `PresentationClock`).
    ///   - signposter: Records each closed slot's `input.latency` event (category ``SignpostCategory/input``).
    ///   - batchSink: Takes each half ring of closed slots (the ledger), or nil.
    public convenience init(presentation: any InputPresentationEstimating,
                            signposter: Signposter = Signposter(category: .input), batchSink: BatchSink? = nil) {
        self.init(table: InputLatencySlotTable(), ring: InputLatencyRing(), presentation: presentation,
                  afterCommit: { CommitBoundary().after($0) }, emit: { Self.signpost($0, to: signposter) },
                  batchSink: batchSink, now: Self.uptimeNanos)
    }

    /// - Parameters:
    ///   - table: The open-slot table.
    ///   - ring: The closed-slot ring (this tracker is its one writer).
    ///   - presentation: The presented-time estimate.
    ///   - afterCommit: Asks for the turn's commit boundary, once per turn with slots open.
    ///   - emit: Records one closed slot.
    ///   - batchSink: Takes each half ring of closed slots, or nil.
    ///   - now: `CLOCK_UPTIME_RAW` nanoseconds now (the `NSEvent.timestamp` clock).
    public init(table: InputLatencySlotTable, ring: InputLatencyRing, presentation: any InputPresentationEstimating,
                afterCommit: @escaping AfterCommit, emit: @escaping Emit, batchSink: BatchSink?,
                now: @escaping @Sendable () -> UInt64) {
        self.table = table
        self.ring = ring
        self.presentation = presentation
        self.afterCommit = afterCommit
        self.emit = emit
        self.batchSink = batchSink
        self.now = now
        pending.reserveCapacity(table.capacity)
    }

    /// Slots opened this turn, waiting for the commit (tests).
    var pendingCount: Int { pending.count }

    /// The newest `count` closed slots, newest first (debug.input).
    public func recent(_ count: Int) -> [InputLatencySlot] {
        ring.recent(count)
    }

    /// Opens a slot for `event`, dispatched now.
    ///
    /// - Parameters:
    ///   - event: The OS event; its timestamp is the `generated` stage and its window gets the presented estimate.
    ///   - kind: What the person did (the caller tells a scroll's first update apart).
    ///   - target: The view it lands in.
    ///   - entrypoint: A person's input or a synthetic one.
    /// - Returns: The slot's token, or nil when the table is full (counted in its `droppedCount`).
    // perf-hot: 0.5us key-dispatch
    public func begin(event: NSEvent, kind: InputEventKind, target: InputTarget,
                      entrypoint: InputEntrypoint) -> InputLatencyToken? {
        begin(kind: kind, target: target, entrypoint: entrypoint, eventTimestamp: event.timestamp, window: event.window)
    }

    /// ``begin(event:kind:target:entrypoint:)`` with the event's fields.
    ///
    /// - Parameters:
    ///   - kind: What the person did.
    ///   - target: The view it lands in.
    ///   - entrypoint: A person's input or a synthetic one.
    ///   - eventTimestamp: Seconds since boot (`NSEvent.timestamp`); 0 or a time after now uses now.
    ///   - window: The event's window, or nil for the window-less app scheduler.
    /// - Returns: The slot's token, or nil when the table is full.
    // perf-hot: 0.5us key-dispatch
    public func begin(kind: InputEventKind, target: InputTarget, entrypoint: InputEntrypoint,
                      eventTimestamp: TimeInterval, window: NSWindow?) -> InputLatencyToken? {
        let arrived = now()
        let generated = Self.generatedNanos(eventTimestamp: eventTimestamp, arrived: arrived)
        guard let token = table.begin(kind: kind, target: target, entrypoint: entrypoint, generated: generated) else {
            return nil
        }
        table.mark(token, .arrivedMain, at: arrived)
        table.mark(token, .dispatchStart, at: arrived)
        presentation.holdLinkForInput(in: window)
        pending.append(Pending(token: token, window: window))
        if pending.count == 1 { afterCommit(closeAtCommit) }
        return token
    }

    /// Stamps `stage` of `token`'s slot, from any thread, once. A mark after the slot closed is refused.
    ///
    /// - Parameters:
    ///   - token: The slot ``begin(event:kind:target:entrypoint:)`` returned.
    ///   - stage: The stage reached.
    ///   - nanos: `CLOCK_UPTIME_RAW` nanoseconds; now when omitted.
    /// - Returns: Whether it wrote.
    // perf-hot: 0.05us key-dispatch
    @discardableResult
    public nonisolated func mark(_ token: InputLatencyToken, _ stage: InputStage, at nanos: UInt64? = nil) -> Bool {
        table.mark(token, stage, at: nanos ?? now())
    }

    /// Records that `token`'s input changed a layer or its contents (Chrome `caused_frame_update`), from any thread.
    @discardableResult
    public nonisolated func markCausedFrameUpdate(_ token: InputLatencyToken) -> Bool {
        table.setCausedFrameUpdate(token)
    }

    /// Stamps `dispatchEnd`: the app's dispatch of `token`'s event returned. The slot closes after this turn's commit.
    // perf-hot: 0.05us key-dispatch
    public func endDispatch(_ token: InputLatencyToken) {
        table.mark(token, .dispatchEnd, at: now())
    }

    /// Closes every slot opened since the last boundary: the commit's time and its presented estimate, then the
    /// ring, the signpost and, each half ring, the batch sink.
    private func closePending(_ outcome: CommitBoundary.Outcome) {
        let commitEnd = now()
        // By index over the slots opened before this boundary: a slot a callee opens meanwhile waits for the next one.
        let count = pending.count
        for index in 0..<count {
            let entry = pending[index]
            if outcome == .committed {
                table.mark(entry.token, .mainCommit, at: commitEnd)
                table.mark(entry.token, .presented,
                           at: presentation.presentedNanos(commitEndNanos: commitEnd, in: entry.window))
            }
            guard let slot = table.close(entry.token) else { continue }
            closedCount &+= 1
            emit(slot)
            if ring.append(slot), let batchSink { batchSink(ring.takeBatch()) }
        }
        if count == pending.count {
            pending.removeAll(keepingCapacity: true)
        } else {
            pending.removeFirst(count)
            afterCommit(closeAtCommit)
        }
    }

    /// The `generated` stage: the event's timestamp in nanoseconds, or `arrived` when it has none or it is later
    /// than `arrived` (the slot table stores later stages relative to it, so it must be the earliest).
    nonisolated static func generatedNanos(eventTimestamp: TimeInterval, arrived: UInt64) -> UInt64 {
        guard eventTimestamp > 0 else { return arrived }
        let nanos = UInt64((eventTimestamp * 1_000_000_000).rounded())
        return nanos > 0 && nanos <= arrived ? nanos : arrived
    }

    /// `CLOCK_UPTIME_RAW` nanoseconds: `NSEvent.timestamp`'s clock and `CACurrentMediaTime`'s.
    public nonisolated static func uptimeNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// Records `slot` as one `input.latency` event: the typed `os_signpost` and the trace ring's instant.
    ///
    /// - Parameters:
    ///   - slot: A closed slot.
    ///   - signposter: A signposter of category ``SignpostCategory/input``.
    public static func signpost(_ slot: InputLatencySlot, to signposter: Signposter) {
        let message = InputLatencySignpostMessage(slot: slot)
        if signposter.isEnabled { signposter.event(.inputLatency, message) }
        Signposter.event(.inputLatency, arg0: message.traceArg0, arg1: message.traceArg1,
                         estimated: slot.presentationSource == .estimatedVsync)
    }
}
