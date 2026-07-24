public import Foundation
internal import os

/// A fixed-capacity ring of recent ``DiagnosticEvent`` values with a
/// non-blocking hot-path recorder.
///
/// The recorder seam is the point of the design: ``record(_:)`` is
/// `nonisolated` and yields onto the current bounded event segment inside one
/// short critical region. There is no per-event `Task { await … }` hop (the
/// cost the string-based `MobileDebugLog.append` pays) and no actor hop on the
/// caller's thread, so it is safe to call from the input and render seams. A
/// single internal consumer `Task` drains ordered event segments and
/// non-droppable clear commands into the ring (the only diagnostic state,
/// held by an inner `actor`), evicting the oldest events past ``capacity``.
///
/// ``export()`` drains the ring into a compact blob: a one-line header carrying
/// a wall-clock anchor and the build stamp, then one short row per event
/// (`tNanos,code,surface,ms,a,b,c`, omitting absent fields). The blob is small
/// by construction (bounded by ``capacity`` rows of integers).
///
/// Inject one instance from the app composition root; do not add a `.shared`
/// singleton.
///
/// ```swift
/// let log = DiagnosticLog()
/// log.record(DiagnosticEvent(.connect))
/// let blob = await log.export()
/// ```
public final class DiagnosticLog: Sendable {
    /// The maximum number of retained events. Oldest are dropped past this.
    public let capacity: Int

    /// The build-identity stamp written into the export header. Exposed so a
    /// caller can also carry it as a top-level field when submitting a bundle.
    public let buildStamp: String

    /// The component producing this log. This is a fixed integer category, not
    /// a device or account identifier.
    public let role: DiagnosticRuntimeRole

    /// Synchronously orders record calls against rare clear operations while
    /// keeping every event segment bounded by ``capacity``.
    private let ingress: Ingress

    /// The inner actor owning the ring buffer and the wall-clock anchor.
    private let store: Store

    /// The drain task. Its closure captures only local stream/store values, so
    /// deinitialization can finish ingress and let accepted clear commands drain
    /// to their acknowledgements without retaining this log.
    private let drainTask: Task<Void, Never>

    /// Creates a diagnostic log.
    ///
    /// - Parameters:
    ///   - capacity: Maximum retained events; oldest drop past this. Defaults to
    ///     `4096`.
    ///   - buildStamp: A short string identifying the running build, written
    ///     into the export header. Defaults to empty.
    ///   - role: The fixed runtime category producing this log. Defaults to
    ///     ``DiagnosticRuntimeRole/unspecified``.
    ///   - anchorWallNanos: Wall-clock time at construction, in nanoseconds since
    ///     the Unix epoch, paired with ``anchorMonotonicNanos`` so export can map
    ///     monotonic event timestamps back to absolute time. Injected for tests;
    ///     defaults to the current time.
    ///   - anchorMonotonicNanos: The monotonic clock reading captured at the same
    ///     instant as ``anchorWallNanos``. Injected for tests; defaults to
    ///     `DispatchTime.now().uptimeNanoseconds`.
    public init(
        capacity: Int = 4096,
        buildStamp: String = "",
        role: DiagnosticRuntimeRole = .unspecified,
        anchorWallNanos: UInt64 = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000_000)),
        anchorMonotonicNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        let capacity = max(1, capacity)
        let buildStamp = DiagnosticReport.sanitizeBuildStamp(buildStamp)
        self.capacity = capacity
        self.buildStamp = buildStamp
        self.role = role
        let store = Store(
            capacity: capacity,
            buildStamp: buildStamp,
            role: role,
            anchorWallNanos: anchorWallNanos,
            anchorMonotonicNanos: anchorMonotonicNanos
        )
        self.store = store
        let (commandStream, commandContinuation) = AsyncStream<DrainCommand>.makeStream(
            bufferingPolicy: .unbounded
        )
        let ingress = Ingress(
            capacity: capacity,
            commandContinuation: commandContinuation
        )
        self.ingress = ingress
        self.drainTask = Task {
            for await command in commandStream {
                switch command {
                case let .events(events):
                    for await event in events {
                        await store.append(event)
                    }
                case let .clear(
                    anchorWallNanos,
                    anchorMonotonicNanos,
                    nextEvents,
                    acknowledgement
                ):
                    await store.clear(
                        anchorWallNanos: anchorWallNanos,
                        anchorMonotonicNanos: anchorMonotonicNanos
                    )
                    acknowledgement.resume()
                    for await event in nextEvents {
                        await store.append(event)
                    }
                }
            }
        }
    }

    deinit {
        ingress.finish()
    }

    /// Record one event. Non-blocking and safe from any thread.
    ///
    /// This is the hot-path API. It only yields the value onto the buffered
    /// stream; the actual ring write happens on the internal drain task. A burst
    /// past the consumer's pace drops the oldest pending events (per
    /// `.bufferingNewest`), never the caller. Repeated
    /// ``DiagnosticEventCode/selectedPathChanged`` values for the same redacted
    /// path class are consumed but not retained, so observer wakeups cannot be
    /// mistaken for transport changes.
    ///
    /// - Parameter event: The event to record.
    public nonisolated func record(_ event: DiagnosticEvent) {
        ingress.record(event)
    }

    /// Snapshot the currently-drained ring and format a compact export blob.
    ///
    /// Reads whatever the drain task has already moved into the ring; it does not
    /// force a flush of events still in flight on the stream (the AsyncStream +
    /// drain design is eventually consistent, which is fine for a human-timed
    /// submit). The result is small by construction (bounded by ``capacity``
    /// integer rows). Tests that need an exact post-record snapshot await
    /// ``processedCount()`` first.
    ///
    /// - Returns: The UTF-8 encoded compact blob.
    public func export() async -> Data {
        await store.export()
    }

    /// Returns a Codable, privacy-safe snapshot with events in chronological
    /// order. Events still pending in the non-blocking stream are not forced to
    /// drain; human-triggered exports naturally observe the most recent drained
    /// state.
    public func snapshot(generatedAt: Date = Date()) async -> DiagnosticReport {
        await store.snapshot(generatedAt: generatedAt)
    }

    /// Starts a fresh diagnostic session by clearing retained events, resetting
    /// the processed count, and capturing a new wall/monotonic clock anchor.
    ///
    /// Clear rotates to a new bounded event segment and inserts a non-droppable
    /// command between the old and new segments. The drain acknowledges the
    /// command only after every retained old-segment event has been consumed and
    /// the store has reset, so no old event can reappear after this returns.
    /// Recording itself remains non-blocking.
    public func clear(
        anchorWallNanos: UInt64 = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000_000)),
        anchorMonotonicNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) async {
        await withCheckedContinuation { acknowledgement in
            ingress.clear(
                anchorWallNanos: anchorWallNanos,
                anchorMonotonicNanos: anchorMonotonicNanos,
                acknowledgement: acknowledgement
            )
        }
    }

    /// The current number of retained events.
    public func count() async -> Int {
        await store.count()
    }

    /// The total number of events the drain task has processed in this session.
    ///
    /// Unlike ``count()`` this never decreases (ring eviction does not lower it),
    /// so it is a stable barrier: after recording `n` events a caller can await
    /// this reaching `n` to know every recorded event has reached the ring,
    /// regardless of capacity. Used by tests to make the async drain
    /// deterministic without sleeping.
    public func processedCount() async -> Int {
        await store.processedCount()
    }

    /// The inner actor that owns the ring and renders the export blob.
    ///
    /// The ring is a fixed-size pre-allocated `[DiagnosticEvent?]` indexed by a
    /// `head` cursor and a saturating `filled` count, so both append and
    /// eviction are O(1): a new event overwrites the slot at `head` and advances
    /// the cursor (no `Array.removeFirst`, which would be O(capacity) per event
    /// once full and would starve the drain task during the exact lag bursts this
    /// log captures).
    private enum DrainCommand: Sendable {
        case events(AsyncStream<DiagnosticEvent>)
        case clear(
            anchorWallNanos: UInt64,
            anchorMonotonicNanos: UInt64,
            nextEvents: AsyncStream<DiagnosticEvent>,
            acknowledgement: CheckedContinuation<Void, Never>
        )
    }

    /// Serializes event-segment rotation without suspending callers. Event
    /// segments use `.bufferingNewest(capacity)` and therefore stay bounded;
    /// the command stream is unbounded only for rare clear controls, which must
    /// never be evicted by diagnostic traffic.
    private final class Ingress: Sendable {
        private struct State: Sendable {
            let capacity: Int
            let commandContinuation: AsyncStream<DrainCommand>.Continuation
            var eventContinuation: AsyncStream<DiagnosticEvent>.Continuation?
            var isFinished = false
        }

        private enum ClearEnqueueResult: Sendable {
            case enqueued(previous: AsyncStream<DiagnosticEvent>.Continuation?)
            case terminated(
                previous: AsyncStream<DiagnosticEvent>.Continuation?,
                next: AsyncStream<DiagnosticEvent>.Continuation
            )
        }

        // lint:allow lock - record is synchronous by contract. The critical
        // region only selects/yields a value or rotates stream continuations;
        // no async work runs while the lock is held.
        private let state: OSAllocatedUnfairLock<State>

        init(
            capacity: Int,
            commandContinuation: AsyncStream<DrainCommand>.Continuation
        ) {
            let (events, eventContinuation) = Self.makeEventSegment(capacity: capacity)
            self.state = OSAllocatedUnfairLock(initialState: State(
                capacity: capacity,
                commandContinuation: commandContinuation,
                eventContinuation: eventContinuation
            ))
            commandContinuation.yield(.events(events))
        }

        func record(_ event: DiagnosticEvent) {
            state.withLock { state in
                guard !state.isFinished else { return }
                state.eventContinuation?.yield(event)
            }
        }

        func clear(
            anchorWallNanos: UInt64,
            anchorMonotonicNanos: UInt64,
            acknowledgement: CheckedContinuation<Void, Never>
        ) {
            let result: ClearEnqueueResult = state.withLock { state in
                guard !state.isFinished else {
                    let (_, next) = Self.makeEventSegment(capacity: state.capacity)
                    return .terminated(previous: nil, next: next)
                }

                let previous = state.eventContinuation
                let (events, continuation) = Self.makeEventSegment(capacity: state.capacity)
                let yieldResult = state.commandContinuation.yield(.clear(
                    anchorWallNanos: anchorWallNanos,
                    anchorMonotonicNanos: anchorMonotonicNanos,
                    nextEvents: events,
                    acknowledgement: acknowledgement
                ))
                switch yieldResult {
                case .enqueued:
                    state.eventContinuation = continuation
                    return .enqueued(previous: previous)
                case .dropped, .terminated:
                    state.isFinished = true
                    state.eventContinuation = nil
                    return .terminated(previous: previous, next: continuation)
                @unknown default:
                    state.isFinished = true
                    state.eventContinuation = nil
                    return .terminated(previous: previous, next: continuation)
                }
            }
            switch result {
            case .enqueued(let previous):
                previous?.finish()
            case let .terminated(previous, next):
                previous?.finish()
                next.finish()
                acknowledgement.resume()
            }
        }

        func finish() {
            let continuations: (
                AsyncStream<DiagnosticEvent>.Continuation?,
                AsyncStream<DrainCommand>.Continuation
            )? = state.withLock { state in
                guard !state.isFinished else { return nil }
                state.isFinished = true
                let eventContinuation = state.eventContinuation
                state.eventContinuation = nil
                return (eventContinuation, state.commandContinuation)
            }
            continuations?.0?.finish()
            continuations?.1.finish()
        }

        private static func makeEventSegment(
            capacity: Int
        ) -> (AsyncStream<DiagnosticEvent>, AsyncStream<DiagnosticEvent>.Continuation) {
            AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(capacity))
        }
    }

    private actor Store {
        private var slots: [DiagnosticEvent?]
        private var head = 0
        private var filled = 0
        private var totalProcessed = 0
        private var selectedPathKind: DiagnosticPathKind?
        private let capacity: Int
        private let buildStamp: String
        private let role: DiagnosticRuntimeRole
        private var anchorWallNanos: UInt64
        private var anchorMonotonicNanos: UInt64

        init(
            capacity: Int,
            buildStamp: String,
            role: DiagnosticRuntimeRole,
            anchorWallNanos: UInt64,
            anchorMonotonicNanos: UInt64
        ) {
            // A zero/negative capacity would make a 0-length ring; clamp to 1 so
            // append always has a slot.
            let clamped = max(1, capacity)
            self.capacity = clamped
            self.buildStamp = buildStamp
            self.role = role
            self.anchorWallNanos = anchorWallNanos
            self.anchorMonotonicNanos = anchorMonotonicNanos
            self.slots = Array(repeating: nil, count: clamped)
        }

        func append(_ event: DiagnosticEvent) {
            totalProcessed += 1
            if let nextPathKind = event.diagnosticPathKind {
                guard nextPathKind != selectedPathKind else { return }
                selectedPathKind = nextPathKind
            }
            slots[head] = event
            head = (head + 1) % capacity
            if filled < capacity {
                filled += 1
            }
        }

        func count() -> Int {
            filled
        }

        func processedCount() -> Int {
            totalProcessed
        }

        func clear(anchorWallNanos: UInt64, anchorMonotonicNanos: UInt64) {
            slots = Array(repeating: nil, count: capacity)
            head = 0
            filled = 0
            totalProcessed = 0
            selectedPathKind = nil
            self.anchorWallNanos = anchorWallNanos
            self.anchorMonotonicNanos = anchorMonotonicNanos
        }

        /// The retained events in chronological order (oldest first).
        ///
        /// When the ring is full the oldest event sits at `head` (the next write
        /// target); when not yet full the oldest is at index 0. Walking `filled`
        /// slots from `start` yields them in record order.
        private func orderedEvents() -> [DiagnosticEvent] {
            let start = filled < capacity ? 0 : head
            var result: [DiagnosticEvent] = []
            result.reserveCapacity(filled)
            for offset in 0..<filled {
                if let event = slots[(start + offset) % capacity] {
                    result.append(event)
                }
            }
            return result
        }

        func snapshot(generatedAt: Date) -> DiagnosticReport {
            DiagnosticReport(
                role: role,
                generatedAt: generatedAt,
                anchorWallNanos: anchorWallNanos,
                anchorMonotonicNanos: anchorMonotonicNanos,
                buildStamp: buildStamp,
                events: orderedEvents()
            )
        }

        func export() -> Data {
            snapshot(generatedAt: Date()).compactExport()
        }
    }
}
