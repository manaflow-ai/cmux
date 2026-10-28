import CmuxNextMetrics
import CmuxNextTrace
import CoreFoundation
public import Foundation

/// EventLatency for the input kinds other than a key press, and for live window resize:
/// each event's `NSEvent` timestamp to the end of the main run loop's next commit that changes content, as Chrome's
/// `EventLatency.<type>.TotalLatency` runs from the OS event's timestamp to the frame that shows it and reports only
/// events that caused a frame update (cc/metrics/event_metrics.h `caused_frame_update`,
/// cc/metrics/compositor_frame_reporter.cc `ReportEventLatencyMetrics`).
///
/// - `NSApplication.sendEvent` stamps each person's mouse press and release, drag and scroll with its event's
///   timestamp (``willDispatch(_:eventTimestamp:)``), and says after the dispatch whether it left content for the
///   turn's commit (``didDispatch(_:changedContent:)``).
/// - Drags coalesce to one stamp per frame, the frame's first, as Chrome reports one scroll update per frame.
/// - A paste (``Kind/paste``) and an input method's commit (``Kind/imeCommit``) are stamped where they happen
///   (``textCommitted(_:eventTimestamp:)``): inside a key press's dispatch they take its timestamp. They insert text,
///   so they change content.
/// - Each live-resize tick is one ``SignpostName/resizeFrame`` stamp (``resizeTick(eventTimestamp:)``), one per frame.
/// - One repeating main run-loop observer at ``CommitBoundary/order`` (``TurnEndObserver``) ends every stamp: a stamp
///   whose event changed content, or whose dispatch was still running (a commit inside a tracking loop shows its
///   input), records its `input.frame.<kind>` or `resize.frame` sample at a committed callout. A stamp that changed
///   nothing is dropped, and so is one ended by a wake (``CommitBoundary/Outcome/missed``: it would hold the idle wait).
///
/// The key press itself is ``Kind/key``: its `key.frame` is ``KeyFrameSignpost``'s, so a key's dispatch opens no
/// stamp here, but a paste or an input method commit it causes takes its timestamp.
///
/// It runs on every pointer event, so it makes no heap allocation: stamps are plain values in a buffer reserved once.
/// With the event's trace category off, a stamp costs one relaxed load (the category flag); the ring's `input.frame`
/// or `resize.frame` async slice (AB at the dispatch with the kind and the age, AE at the commit with how it ended) is
/// written only while the category records. While the keystroke-timing gate is closed
/// (``TraceRuntime/isKeyTimingSuppressed``, secure input), an input method commit and anything a key press causes
/// record nothing.
///
/// ```swift
/// let dispatch = inputFrames.willDispatch(.mouseDown, eventTimestamp: event.timestamp)
/// super.sendEvent(event)
/// inputFrames.didDispatch(dispatch, changedContent: window.viewsNeedDisplay)
/// ```
@MainActor
public final class InputFrameSignpost {
    /// The input kinds of `input.frame` (the begin record's `arg0` bits 0-7 is ``rawValue``; fixed).
    public nonisolated enum Kind: UInt8, Sendable, CaseIterable {
        /// A key press: its own frame is `key.frame` (``KeyFrameSignpost``); here it only lends its timestamp.
        case key = 1
        /// A mouse button press.
        case mouseDown = 2
        /// A mouse button release.
        case mouseUp = 3
        /// A drag, one per frame.
        case drag = 4
        /// A scroll event (wheel, trackpad or momentum).
        case scroll = 5
        /// An input method's commit of composed text.
        case imeCommit = 6
        /// A paste.
        case paste = 7

        /// The `input.frame` histogram of this kind; nil for ``key`` (`key.frame` is ``KeyFrameSignpost``'s).
        var histogramKind: HistogramID.InputKind? {
            switch self {
            case .key: nil
            case .mouseDown: .mouseDown
            case .mouseUp: .mouseUp
            case .drag: .drag
            case .scroll: .scroll
            case .imeCommit: .imeCommit
            case .paste: .paste
            }
        }
    }

    /// What a stamp measures.
    enum Source: Equatable {
        /// An input event of a kind.
        case input(Kind)
        /// A live-resize tick.
        case resize

        var name: SignpostName {
            switch self {
            case .input: .inputFrame
            case .resize: .resizeFrame
            }
        }

        /// The begin record's `arg0` bits 0-7 (0 for a resize tick).
        var traceCode: UInt64 {
            switch self {
            case let .input(kind): UInt64(kind.rawValue)
            case .resize: 0
            }
        }
    }

    /// The event whose dispatch runs now.
    enum Current {
        /// None, or one that is not stamped.
        case none
        /// A key press, with its event timestamp.
        case key(TimeInterval)
        /// A stamped event, by its serial.
        case stamp(UInt32)
    }

    /// One dispatch begun by ``willDispatch(_:eventTimestamp:)``: give it back to ``didDispatch(_:changedContent:)``.
    public struct Dispatch {
        /// The dispatch it runs inside, restored when it ends.
        let outer: Current
    }

    /// One stamped event or resize tick, waiting for its turn's commit.
    struct Stamp {
        let serial: UInt32
        let source: Source
        /// `CLOCK_UPTIME_RAW` nanoseconds of the event (its timestamp; the stamp time when it had none).
        let startNanos: UInt64
        /// The ring took its AB: its end writes the AE.
        let traced: Bool
        /// It left content for a commit.
        var changed: Bool
        /// Its dispatch has not returned.
        var inDispatch: Bool
    }

    private let trace: TraceRuntime
    private let clock: TraceClock
    private let metrics: Metrics
    private let capacity: Int
    private var pending: ContiguousArray<Stamp> = []
    private var current: Current = .none
    private var serial: UInt32 = 0

    /// The app's: the process's trace runtime and metrics store, ended by an observer on the main run loop.
    public convenience init() {
        self.init(trace: .shared)
        TurnEndObserver.install { [weak self] activity in
            guard let self else { return false }
            self.runLoopReached(activity)
            return true
        }
    }

    /// Stamps with no observer: the caller fires ``runLoopReached(_:)`` (tests).
    ///
    /// - Parameters:
    ///   - trace: The runtime whose ring and metrics store take the records.
    ///   - clock: `CLOCK_UPTIME_RAW` nanoseconds, `NSEvent.timestamp`'s clock (tests pass a counter).
    ///   - capacity: The most stamps one turn holds; an event past it records nothing.
    init(trace: TraceRuntime, clock: TraceClock = TraceClock(), capacity: Int = 32) {
        self.trace = trace
        self.clock = clock
        metrics = Metrics(runtime: trace)
        self.capacity = capacity
        pending.reserveCapacity(capacity)
    }

    /// Stamps waiting for their commit (tests).
    var openCount: Int { pending.count }

    /// An event of `kind` is dispatched now: a key press lends its timestamp to what it causes, a pointer event opens
    /// a stamp (a drag joins its frame's), anything else (nil) is no stamped event.
    ///
    /// - Parameters:
    ///   - kind: The event's kind; nil for an event that is not stamped (and for the app's own synthetic input).
    ///   - eventTimestamp: `NSEvent.timestamp`, seconds since boot; 0 when it has none (the dispatch time is used).
    /// - Returns: What ``didDispatch(_:changedContent:)`` takes after the dispatch.
    // perf-hot: 100ns main-turn
    public func willDispatch(_ kind: Kind?, eventTimestamp: TimeInterval) -> Dispatch {
        let dispatch = Dispatch(outer: current)
        guard let kind else {
            current = .none
            return dispatch
        }
        if kind == .key {
            current = .key(eventTimestamp)
        } else if kind == .drag, let index = pending.lastIndex(where: { $0.source == .input(.drag) }) {
            pending[index].inDispatch = true
            current = .stamp(pending[index].serial)
        } else {
            current = open(.input(kind), eventTimestamp: eventTimestamp, changed: false, inDispatch: true).map(Current.stamp) ?? .none
        }
        return dispatch
    }

    /// The dispatch ``willDispatch(_:eventTimestamp:)`` began returned.
    ///
    /// - Parameters:
    ///   - dispatch: What ``willDispatch(_:eventTimestamp:)`` returned.
    ///   - changedContent: Whether the dispatch left content for the turn's commit; read only for a stamp that
    ///     changed nothing yet.
    // perf-hot: 100ns main-turn
    public func didDispatch(_ dispatch: Dispatch, changedContent: @autoclosure () -> Bool) {
        if case let .stamp(serial) = current, let index = index(of: serial) {
            pending[index].inDispatch = false
            if !pending[index].changed, changedContent() { pending[index].changed = true }
        }
        current = dispatch.outer
    }

    /// Text was pasted (``Kind/paste``) or an input method committed text (``Kind/imeCommit``) now. Inside a key
    /// press's dispatch it takes the key's timestamp; otherwise `eventTimestamp`. It inserts text, so it counts as
    /// changing content. Once per dispatch for each kind.
    ///
    /// - Parameters:
    ///   - kind: ``Kind/paste`` or ``Kind/imeCommit``.
    ///   - eventTimestamp: The event that caused it (the tap's action event), 0 when none did.
    public func textCommitted(_ kind: Kind, eventTimestamp: TimeInterval) {
        var timestamp = eventTimestamp
        var fromKey = false
        switch current {
        case let .key(keyTimestamp):
            timestamp = keyTimestamp
            fromKey = true
        case let .stamp(serial):
            if let index = index(of: serial), pending[index].source == .input(kind) { return }
        case .none:
            break
        }
        if fromKey || kind == .imeCommit, trace.isKeyTimingSuppressed { return }
        guard let serial = open(.input(kind), eventTimestamp: timestamp, changed: true, inDispatch: false) else { return }
        if fromKey { current = .stamp(serial) }
    }

    /// A live-resize tick: the window's frame changed during a live resize. One stamp per frame.
    ///
    /// - Parameter eventTimestamp: The drag that moved the window's edge (the tap's action event), 0 when none.
    public func resizeTick(eventTimestamp: TimeInterval) {
        guard !pending.contains(where: { $0.source == .resize }) else { return }
        _ = open(.resize, eventTimestamp: eventTimestamp, changed: true, inDispatch: false)
    }

    /// Ends every stamp at the observer's callout: before waiting or on exit a stamp that changed content (or whose
    /// dispatch still runs) records its sample, after a wake it is missed; a stamp that changed nothing is dropped.
    // perf-hot: 100ns main-turn
    func runLoopReached(_ activity: CFRunLoopActivity) {
        guard !pending.isEmpty else { return }
        let missed = activity == .afterWaiting
        let endNanos = clock.nowNanos()
        for stamp in pending {
            let showed = stamp.changed || stamp.inDispatch
            let code: UInt64
            if showed, !missed {
                record(stamp, micros: endNanos > stamp.startNanos ? (endNanos - stamp.startNanos) / 1_000 : 0)
                code = Signposter.EndCode.ended
            } else {
                code = showed ? Signposter.EndCode.missed : Signposter.EndCode.noFrame
            }
            if stamp.traced { trace.asyncEndRecorded(stamp.source.name, id: UInt64(stamp.serial), arg0: code) }
        }
        pending.removeAll(keepingCapacity: true)
    }

    private func record(_ stamp: Stamp, micros: UInt64) {
        let sample = Int64(truncatingIfNeeded: micros)
        switch stamp.source {
        case let .input(kind):
            if let histogram = kind.histogramKind { metrics.record(.inputFrame(histogram), sample) }
        case .resize:
            metrics.record(.resizeFrame, sample)
        }
    }

    /// Opens a stamp; nil when the turn holds ``capacity`` stamps. Writes the ring's AB only while the source's
    /// category records: that flag is the one load a stamp makes when the category is off.
    private func open(_ source: Source, eventTimestamp: TimeInterval, changed: Bool, inDispatch: Bool) -> UInt32? {
        guard pending.count < capacity else { return nil }
        serial = serial == .max ? 1 : serial + 1
        let name = source.name
        let traced = trace.isEnabled(categoryBit: name.traceCategory.traceBit)
        let eventNanos = Self.uptimeNanos(eventTimestamp)
        var startNanos = eventNanos
        var wroteBegin = false
        if traced || eventNanos == 0 {
            let now = clock.nowNanos()
            if eventNanos == 0 || eventNanos > now { startNanos = now }
            if traced {
                let ageMilliseconds = eventNanos == 0 ? -1 : Double(now - startNanos) / 1_000_000
                wroteBegin = trace.asyncBegin(name, id: UInt64(serial),
                                              arg0: source.traceCode | Signposter.inputAgeBits(milliseconds: ageMilliseconds))
            }
        }
        pending.append(Stamp(serial: serial, source: source, startNanos: startNanos, traced: wroteBegin, changed: changed,
                             inDispatch: inDispatch))
        return serial
    }

    private func index(of serial: UInt32) -> Int? {
        pending.lastIndex { $0.serial == serial }
    }

    /// `CLOCK_UPTIME_RAW` nanoseconds of an `NSEvent.timestamp` (seconds since boot), 0 for none.
    nonisolated static func uptimeNanos(_ timestamp: TimeInterval) -> UInt64 {
        guard timestamp > 0, timestamp.isFinite, timestamp < Double(UInt64.max >> 1) / 1e9 else { return 0 }
        return UInt64((timestamp * 1e9).rounded())
    }
}
