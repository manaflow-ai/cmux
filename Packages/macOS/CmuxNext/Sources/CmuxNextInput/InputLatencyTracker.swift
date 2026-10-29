public import AppKit
public import CmuxNextInputCore
public import CmuxNextSignposts
public import CmuxNextWakeups
import Darwin

/// EventLatency for cmux: each tracked input event's stages, from its OS timestamp to the frame that shows it
/// (plans/cmux-next/chrome-parity/p04-input.md, section 3 (I), task 004).
///
/// Chrome keeps one `EventMetrics` per event (cc/metrics/event_metrics.h) and closes it at the presentation feedback
/// of the frame that shows it (cc/metrics/compositor_frame_reporter.cc), which for a renderer is a later frame than
/// the browser's. Here:
/// - ``begin(event:kind:target:entrypoint:arrivedMain:)`` opens a slot in the lock-free ``InputLatencySlotTable``,
///   stamps `generated` (the event's OS time), `arrivedMain` when the caller knows it and `dispatchStart`, holds the
///   window's display link for a few frames and arms the turn's commit boundary (``InputTurnBoundary``).
/// - ``mark(_:_:at:)`` stamps any other stage from any thread, once (a terminal writer, a text input helper).
/// - ``endDispatch(_:)`` stamps `dispatchEnd` after the app's dispatch returned.
/// - After the Core Animation commit that ends the turn, every slot opened in the turn gets `mainCommit`. What shows
///   a view's input is that commit: its presented time is the commit's estimate. What shows a terminal's, a page's or
///   an agent pane's (``InputTarget/showsInLaterFrame``) is the target's own frame, later: the slot stays open until
///   its producer stamps `contentSubmitted` (or `presented`, with host feedback), and its presented time is that
///   submission's estimate. One that submits nothing within ``contentDeadlineNanos`` closes with `presented`
///   skipped (no echo), so the table cannot fill.
/// - A Chromium page in its own host process reports when the frame that shows an input reached the display, by the
///   input's event time (``hostPresented(eventNanos:at:)``): that time closes the page's slot with
///   source ``InputPresentationSource/hostFeedback``, as the viz presentation feedback of a renderer's frame closes
///   its events' `EventMetrics` (cc/metrics/compositor_frame_reporter.cc, `DidPresentCompositorFrame`). While no
///   page reports (``pagesReportPresentation`` off: an in-process page, a host whose fork has no feedback), a page's
///   slot closes as a view's does, with its turn's commit estimate.
/// - In DEV and bench builds a WebKit page reports, by its own clock, when the frame after its handler of an input
///   painted (``WebPageInputTiming``): ``pagePresented(_:eventNanos:at:)`` closes the page's slot with
///   source ``InputPresentationSource/pageEstimated``.
/// - Estimates come from ``InputPresentationEstimating`` (`PresentationClock`): resolved by the window's next real
///   tick, with how the vsync was found (``InputPresentationSource``) and whether the display has a variable refresh
///   rate. Then the slot closes, goes into the single-writer ``InputLatencyRing`` and is recorded as one
///   ``SignpostName/inputLatency`` event. A missed commit (``CommitBoundary/Outcome/missed``) closes a view's slot
///   with `mainCommit` and `presented` skipped, so readers drop it instead of counting idle time.
/// - Every half ring goes to the batch sink (the ledger) as one array.
/// - A commit the run loop ran before a slot's dispatch returned ran inside that dispatch (a menu, a sheet, a tracking
///   loop): the slot gets `causedFrameUpdate`, as its input produced that frame.
/// - A slot opened with an ``InputFrameInterval`` also carries the older `key.frame` or `key.scroll_frame` interval
///   (``InputFrameIntervals``), begun with the slot and ended at its turn's commit with the slot's target then, so
///   their readers keep working with no second classification or commit boundary.
///
/// The per-event path makes no allocation, takes no lock and builds no `String`: the pending and waiting lists are
/// reserved at init, the commit boundary is two run-loop observers made once and armed by a flag
/// (``InputCommitObserver``), and each window's estimate queue is made at its first input. The test
/// `perEventPathAllocatesNothing` measures it with the real boundary, `PresentationClock` and trace point. The
/// `input.latency` os_signpost is typed numbers the log system formats only when something reads them; that
/// emission is the log system's cost and is not part of the measured claim.
///
/// ```swift
/// let tracker = InputLatencyTracker(presentation: presentationClock)
/// let token = tracker.begin(event: event, kind: .keyPress, target: .terminal, entrypoint: .person)
/// super.sendEvent(event)
/// if let token { tracker.endDispatch(token) }
/// ```
public final class InputLatencyTracker {
    /// Records one closed slot (the `input.latency` signpost and trace point; tests count).
    public typealias Emit = @MainActor (InputLatencySlot) -> Void
    /// Takes one batch of closed slots, oldest first (the ledger).
    public typealias BatchSink = @MainActor ([InputLatencySlot]) -> Void

    /// How long after its turn's commit a slot whose frame comes from its target waits for that frame before it
    /// closes with no presented time (p04-input.md: no echo at 500 ms).
    public nonisolated static let contentDeadlineNanos: UInt64 = 500_000_000

    /// One slot opened this turn, waiting for the turn's commit.
    struct Pending {
        let token: InputLatencyToken
        let window: NSWindow?
        /// Where the input landed; ``setTarget(_:_:)`` changes it while the turn is open.
        var target: InputTarget
        /// What the person did (a page's report names its event's kind, ``pagePresented(_:eventNanos:at:)``).
        let kind: InputEventKind
        /// The slot carries a `key.frame` or `key.scroll_frame` interval.
        let hasFrameInterval: Bool
    }

    /// One slot past its turn's commit, waiting for its target's frame.
    struct Waiting {
        let token: InputLatencyToken
        let window: NSWindow?
        let target: InputTarget
        let kind: InputEventKind
        /// The latest `contentSubmitted` that still counts (`CLOCK_UPTIME_RAW`).
        let deadline: UInt64
    }

    /// The open slots: any thread stamps stages here through ``mark(_:_:at:)``.
    public nonisolated let table: InputLatencySlotTable
    /// `CLOCK_UPTIME_RAW` nanoseconds now.
    private nonisolated let now: @Sendable () -> UInt64
    private let ring: InputLatencyRing
    private let presentation: any InputPresentationEstimating
    private let boundary: any InputTurnBoundary
    private let emit: Emit
    /// Takes each half ring of closed slots (and each ``flushClosedSlots()``). The composition root may set it once after
    /// init, when the sink needs the tracker (``droppedTotal``).
    public var batchSink: BatchSink?
    private let frameIntervals: (any InputFrameIntervals)?
    /// Slots opened since the last boundary; reserved to the table's capacity, so appends never allocate.
    var pending: ContiguousArray<Pending> = []
    /// Slots waiting for their target's frame; reserved to the table's capacity.
    var waiting: ContiguousArray<Waiting> = []
    /// One estimate queue per window that had a tracked input (and one for the app scheduler).
    private var queues: ContiguousArray<InputPresentedQueue> = []

    /// Slots closed since launch.
    public private(set) var closedCount: UInt64 = 0
    /// The slot of the key press being dispatched now, from its ``begin(kind:target:entrypoint:eventTimestamp:window:arrivedMain:frameInterval:)``
    /// to its ``endDispatch(_:)``: a terminal arms its echo stages on it and sends it to the daemon as the key's flow
    /// (``CmuxNextInputCore/InputLatencyToken/keyFlow``; p04-input-094). A key dispatched inside another
    /// key's dispatch (a held key run again) is the dispatching key until its own dispatch ends; then the outer one is
    /// again.
    public var dispatchingKey: InputLatencyToken? { dispatchingKeys.top }
    /// The key slots in dispatch, innermost on top: a fixed inline stack, so the per-key path never allocates.
    private var dispatchingKeys = DispatchingKeys()
    /// Host presentation reports since launch that matched no open Chromium page slot (``hostPresented(eventNanos:at:)``):
    /// an input the tracker did not track, a slot that closed at its deadline first, or a report with no usable time.
    public internal(set) var unmatchedHostPresentations: UInt64 = 0
    /// Chromium pages report the frame that shows each input (``hostPresented(eventNanos:at:)``): set by the page's
    /// host from its `ready` frame. On, a ``InputTarget/chromiumPage`` slot waits for that report after its turn; off
    /// (no fork has the feedback yet, and an in-process page never reports), it closes with its turn's commit
    /// estimate, source ``InputPresentationSource/estimatedVsync`` (p04-input.md).
    public var pagesReportPresentation = false

    /// A tracker on the main run loop's commit, an `input` signposter and `CLOCK_UPTIME_RAW`.
    ///
    /// - Parameters:
    ///   - presentation: The presented-time estimate (the app's `PresentationClock`).
    ///   - signposter: Records each closed slot's `input.latency` event (category ``SignpostCategory/input``).
    ///   - batchSink: Takes each half ring of closed slots (the ledger), or nil.
    ///   - frameIntervals: Records the `key.frame` and `key.scroll_frame` intervals of the slots that carry one.
    public convenience init(presentation: any InputPresentationEstimating,
                            signposter: Signposter = Signposter(category: .input), batchSink: BatchSink? = nil,
                            frameIntervals: (any InputFrameIntervals)? = InputFrameSignposts()) {
        self.init(table: InputLatencySlotTable(), ring: InputLatencyRing(), presentation: presentation,
                  boundary: InputCommitObserver(), emit: { Self.signpost($0, to: signposter) },
                  batchSink: batchSink, frameIntervals: frameIntervals, now: Self.uptimeNanos)
    }

    /// - Parameters:
    ///   - table: The open-slot table.
    ///   - ring: The closed-slot ring (this tracker is its one writer).
    ///   - presentation: The presented-time estimate.
    ///   - boundary: The turn's commit boundary; the tracker starts it here and arms it once per turn with slots.
    ///   - emit: Records one closed slot.
    ///   - batchSink: Takes each half ring of closed slots, or nil.
    ///   - frameIntervals: Records the `key.frame` and `key.scroll_frame` intervals of the slots that carry one, or nil.
    ///   - now: `CLOCK_UPTIME_RAW` nanoseconds now (the `NSEvent.timestamp` clock).
    public init(table: InputLatencySlotTable, ring: InputLatencyRing, presentation: any InputPresentationEstimating,
                boundary: any InputTurnBoundary, emit: @escaping Emit, batchSink: BatchSink?,
                frameIntervals: (any InputFrameIntervals)? = nil, now: @escaping @Sendable () -> UInt64) {
        self.table = table
        self.ring = ring
        self.presentation = presentation
        self.boundary = boundary
        self.emit = emit
        self.batchSink = batchSink
        self.frameIntervals = frameIntervals
        self.now = now
        pending.reserveCapacity(table.capacity)
        waiting.reserveCapacity(table.capacity)
        boundary.start { [weak self] in self?.turnEnded($0) }
    }

    /// Slots opened this turn, waiting for the commit (tests).
    var pendingCount: Int { pending.count }
    /// Slots waiting for their target's frame (tests).
    var waitingCount: Int { waiting.count }

    /// The newest `count` closed slots, newest first (debug.input).
    public func recent(_ count: Int) -> [InputLatencySlot] {
        ring.recent(count)
    }

    /// Slots lost since launch before any batch carried them: the ones the ring overwrote and the ones the full table
    /// refused (an ``InputLatencyBatch``'s cumulative `droppedTotal`).
    public var droppedTotal: UInt64 {
        ring.droppedCount &+ table.droppedCount
    }

    /// Hands the slots closed since the last batch to ``batchSink`` now, however few: a `debug.input` read counts every
    /// closed slot, not only those of full half rings. Nothing when no slot closed since the last batch or there is no
    /// sink.
    public func flushClosedSlots() {
        guard let batchSink else { return }
        let batch = ring.takeBatch()
        if !batch.isEmpty { batchSink(batch) }
    }

    /// Opens a slot for `event`, dispatched now.
    ///
    /// - Parameters:
    ///   - event: The OS event; its timestamp is the `generated` stage and its window gets the presented estimate.
    ///   - kind: What the person did (the caller tells a scroll's first update apart).
    ///   - target: The view it lands in.
    ///   - entrypoint: A person's input or a synthetic one.
    ///   - arrivedMain: When the event reached the main thread (`CLOCK_UPTIME_RAW`; the turn's wake from the input
    ///     tap or the pending-input state), or nil when unknown: the stage stays skipped, not equal to dispatchStart.
    /// - Returns: The slot's token, or nil when the table is full (counted in its `droppedCount`).
    // perf-hot: 0.5us key-dispatch
    // perf-hot: 0.5us input-latency-mark
    public func begin(event: NSEvent, kind: InputEventKind, target: InputTarget, entrypoint: InputEntrypoint,
                      arrivedMain: UInt64? = nil) -> InputLatencyToken? {
        begin(kind: kind, target: target, entrypoint: entrypoint, eventTimestamp: event.timestamp, window: event.window,
              arrivedMain: arrivedMain, keyCode: kind.isKey ? event.keyCode : 0)
    }

    /// ``begin(event:kind:target:entrypoint:arrivedMain:)`` with the event's fields.
    ///
    /// - Parameters:
    ///   - kind: What the person did.
    ///   - target: The view it lands in.
    ///   - entrypoint: A person's input or a synthetic one.
    ///   - eventTimestamp: Seconds since boot (`NSEvent.timestamp`); 0 or a time after now uses now.
    ///   - window: The window that presents the response (a page window's owner), or nil for the window-less app
    ///     scheduler.
    ///   - arrivedMain: When the event reached the main thread, or nil when unknown (also when 0 or after now).
    ///   - frameInterval: The older interval the slot also carries (`key.frame`, `key.scroll_frame`), or nil.
    ///   - keyCode: The virtual key code of a key event (pairs its press and release into one interaction), else 0.
    /// - Returns: The slot's token, or nil when the table is full.
    // perf-hot: 0.5us key-dispatch
    // perf-hot: 0.5us input-latency-mark
    public func begin(kind: InputEventKind, target: InputTarget, entrypoint: InputEntrypoint,
                      eventTimestamp: TimeInterval, window: NSWindow?,
                      arrivedMain: UInt64? = nil, frameInterval: InputFrameInterval? = nil,
                      keyCode: UInt16 = 0) -> InputLatencyToken? {
        let dispatchStart = now()
        let arrived = arrivedMain.flatMap { $0 != 0 && $0 <= dispatchStart ? $0 : nil }
        let generated = Self.generatedNanos(eventTimestamp: eventTimestamp, arrived: arrived ?? dispatchStart)
        guard let token = table.begin(kind: kind, target: target, entrypoint: entrypoint, generated: generated,
                                      keyCode: keyCode) else {
            return nil
        }
        if let arrived { table.mark(token, .arrivedMain, at: arrived) }
        table.mark(token, .dispatchStart, at: dispatchStart)
        presentation.holdLinkForInput(in: window)
        var hasFrameInterval = false
        if let frameInterval, let frameIntervals {
            frameIntervals.begin(token, frameInterval, target: target, eventTimestamp: eventTimestamp)
            hasFrameInterval = true
        }
        pending.append(Pending(token: token, window: window, target: target, kind: kind, hasFrameInterval: hasFrameInterval))
        if kind == .keyPress { dispatchingKeys.push(token) }
        boundary.arm()
        return token
    }

    /// Stamps `stage` of `token`'s slot, from any thread, once. A mark after the slot closed is refused.
    ///
    /// A terminal's, page's or agent pane's slot stays open after its turn: its producer stamps the cross-process
    /// stages and then `contentSubmitted` (the frame that shows the input), which closes it at the next main turn.
    ///
    /// - Parameters:
    ///   - token: The slot ``begin(event:kind:target:entrypoint:arrivedMain:)`` returned.
    ///   - stage: The stage reached.
    ///   - nanos: `CLOCK_UPTIME_RAW` nanoseconds; now when omitted.
    /// - Returns: Whether it wrote.
    // perf-hot: 0.05us key-dispatch
    // perf-hot: 0.05us input-latency-mark
    @discardableResult
    public nonisolated func mark(_ token: InputLatencyToken, _ stage: InputStage, at nanos: UInt64? = nil) -> Bool {
        table.mark(token, stage, at: nanos ?? now())
    }

    /// Records that `token`'s input changed a layer or its contents (Chrome `caused_frame_update`), from any thread.
    @discardableResult
    public nonisolated func markCausedFrameUpdate(_ token: InputLatencyToken) -> Bool {
        table.setCausedFrameUpdate(token)
    }

    /// Sets the view `token`'s input landed in once its dispatch knows it (the layout took a scroll the view under the
    /// pointer would have had): the slot closes as that target's, and its frame interval ends with it.
    ///
    /// - Parameters:
    ///   - token: A slot opened this turn.
    ///   - target: Where the input landed.
    public func setTarget(_ token: InputLatencyToken, _ target: InputTarget) {
        table.setTarget(token, target)
        if let index = pending.lastIndex(where: { $0.token == token }) { pending[index].target = target }
    }

    /// Stamps `dispatchEnd`: the app's dispatch of `token`'s event returned. The slot closes after this turn's commit.
    // perf-hot: 0.05us key-dispatch
    // perf-hot: 0.05us input-latency-mark
    public func endDispatch(_ token: InputLatencyToken) {
        table.mark(token, .dispatchEnd, at: now())
        dispatchingKeys.remove(token)
    }

    /// Drops `token`'s slot, opened this turn, without recording it: its event was taken by a cmux path that runs it
    /// again later (a creation hold), whose second dispatch opens the slot that counts. One slot per input: the first
    /// pass of a held key is not a key of its own (first-seconds-evidence.md, item 4 of first-keys-proof.md).
    public func discard(_ token: InputLatencyToken) {
        guard let index = pending.lastIndex(where: { $0.token == token }) else { return }
        let entry = pending.remove(at: index)
        if entry.hasFrameInterval { frameIntervals?.end(token, target: entry.target, outcome: .missed) }
        dispatchingKeys.remove(token)
        _ = table.close(token)
    }

    // MARK: Closing

    /// The turn's commit ended: stamps `mainCommit` on the slots opened before it, asks for the presented estimate
    /// of the views' slots, moves the others to the waiting list, then checks that list.
    private func turnEnded(_ outcome: CommitBoundary.Outcome) {
        let commitEnd = now()
        // By index over the slots opened before this boundary: a slot a callee opens meanwhile waits for the next one.
        let count = pending.count
        for index in 0..<count {
            let entry = pending[index]
            if outcome == .committed {
                table.mark(entry.token, .mainCommit, at: commitEnd)
                // A commit before the slot's dispatch returned ran inside that dispatch: its input produced the frame.
                if table.time(entry.token, .dispatchEnd) == nil { table.setCausedFrameUpdate(entry.token) }
            }
            if entry.hasFrameInterval { frameIntervals?.end(entry.token, target: entry.target, outcome: outcome) }
            if waitsForLaterFrame(entry.target) {
                waiting.append(Waiting(token: entry.token, window: entry.window, target: entry.target, kind: entry.kind,
                                       deadline: commitEnd &+ Self.contentDeadlineNanos))
            } else if outcome == .committed {
                awaitPresented(entry.token, committedAt: commitEnd, in: entry.window)
            } else {
                close(entry.token, presented: nil)
            }
        }
        if count == pending.count {
            pending.removeAll(keepingCapacity: true)
        } else {
            pending.removeFirst(count)
        }
        checkWaiting(at: commitEnd)
        if !pending.isEmpty || !waiting.isEmpty { boundary.arm() }
    }

    /// A slot of `target` stays open past its turn for the target's own frame. A Chromium page's frame time comes
    /// only from its host's report, so a page waits only while pages report.
    private func waitsForLaterFrame(_ target: InputTarget) -> Bool {
        target == .chromiumPage ? pagesReportPresentation : target.showsInLaterFrame
    }

    /// Asks for the estimate of every waiting slot whose target submitted its frame, and closes those that took
    /// longer than ``contentDeadlineNanos`` (no echo) or whose producer stamped `presented` itself.
    private func checkWaiting(at time: UInt64) {
        var kept = 0
        for index in waiting.indices {
            let entry = waiting[index]
            if table.time(entry.token, .presented) != nil {
                close(entry.token, presented: nil)
            } else if let submitted = table.time(entry.token, .contentSubmitted) {
                if submitted <= entry.deadline {
                    awaitPresented(entry.token, committedAt: submitted, in: entry.window)
                } else {
                    close(entry.token, presented: nil)
                }
            } else if time > entry.deadline {
                close(entry.token, presented: nil)
            } else {
                waiting[kept] = entry
                kept += 1
            }
        }
        if kept < waiting.count { waiting.removeLast(waiting.count - kept) }
    }

    /// Asks the presentation clock when content committed at `nanos` in `window` reaches the glass; the slot closes
    /// when it answers.
    private func awaitPresented(_ token: InputLatencyToken, committedAt nanos: UInt64, in window: NSWindow?) {
        let queue = presentedQueue(for: window)
        queue.enqueue(token)
        presentation.presented(committedAt: nanos, in: window, queue.resolve)
    }

    /// The estimate queue of `window`, made at its first use (one per window, not per input). A queue whose window
    /// closed is dropped then, and its slots close with no presented time.
    private func presentedQueue(for window: NSWindow?) -> InputPresentedQueue {
        for queue in queues where queue.serves(window) { return queue }
        var index = queues.count
        while index > 0 {
            index -= 1
            guard queues[index].isAbandoned else { continue }
            queues.remove(at: index).abandon()
        }
        let queue = InputPresentedQueue(window: window, capacity: table.capacity) { [weak self] token, estimate in
            self?.close(token, presented: estimate)
        }
        queues.append(queue)
        return queue
    }

    /// Closes `token`'s slot: the estimate, when there is one and no producer stamped `presented`, then the ring,
    /// the signpost and, each half ring, the batch sink.
    func close(_ token: InputLatencyToken, presented estimate: PresentedEstimate?) {
        if let estimate, table.mark(token, .presented, at: estimate.nanos) {
            table.setPresentationSource(token, InputPresentationSource(estimate.basis))
            if estimate.isVariableRefresh { table.setVariableRefresh(token) }
        }
        guard let slot = table.close(token) else { return }
        closedCount &+= 1
        emit(slot)
        if ring.append(slot), let batchSink { batchSink(ring.takeBatch()) }
    }

    // MARK: Clock and signpost

    /// The `generated` stage: the event's timestamp in nanoseconds, or `arrived` when it has none or it is later
    /// than `arrived` (the slot table stores later stages relative to it, so it must be the earliest).
    nonisolated static func generatedNanos(eventTimestamp: TimeInterval, arrived: UInt64) -> UInt64 {
        let nanos = eventNanos(eventTimestamp)
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
        tracePoint(message, slot: slot)
    }

    /// Records `slot`'s trace ring instant, "estimated" only when its presented time is an estimate (not skipped).
    public static func tracePoint(_ message: InputLatencySignpostMessage, slot: InputLatencySlot) {
        Signposter.event(.inputLatency, arg0: message.traceArg0, arg1: message.traceArg1,
                         estimated: slot.reached(.presented) && slot.presentationSource.isEstimate)
    }
}

extension InputTarget {
    /// The input shows in a frame its target submits after the app's commit (a terminal's renderer, a page's
    /// compositor, an agent pane's web view), so its slot stays open until that frame (Chrome closes a renderer's
    /// events at the renderer's frame, not the browser's).
    public nonisolated var showsInLaterFrame: Bool {
        switch self {
        case .terminal, .chromiumPage, .webkitPage, .agentPane: true
        case .textView, .layout, .sidebar, .palette, .other: false
        }
    }
}

extension InputPresentationSource {
    /// The slot's source for an estimate of `basis`: Chrome's `kVSync` only for a real tick after the commit.
    public nonisolated init(_ basis: PresentedEstimate.Basis) {
        switch basis {
        case .heldVsync: self = .estimatedVsync
        case .extrapolated: self = .extrapolatedVsync
        case .nominal: self = .nominalRefresh
        }
    }
}
