public import Foundation

/// A fixed-capacity ring of recent ``DiagnosticEvent`` values with a lock-free
/// hot-path recorder.
///
/// The recorder seam is the point of the design: ``record(_:)`` is
/// `nonisolated` and does nothing but `continuation.yield(event)` on an
/// `AsyncStream<DiagnosticEvent>.Continuation` created with
/// `.bufferingNewest(capacity)`. There is no per-event `Task { await … }` hop
/// (the cost the string-based `MobileDebugLog.append` pays), no lock, and no
/// actor hop on the caller's thread, so it is safe to call from the input and
/// render seams. A single internal consumer `Task` drains the stream into the
/// ring (the only mutable state, held by an inner `actor`), evicting the oldest
/// events past ``capacity``.
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

    /// The continuation the hot path yields onto. `.bufferingNewest(capacity)`
    /// drops the oldest pending event if the consumer falls behind, so a burst
    /// can never block the recorder or grow unboundedly.
    private let continuation: AsyncStream<Message>.Continuation

    /// The inner actor owning the ring buffer and the wall-clock anchor.
    private let store: Store

    /// The drain task. Held so it is cancelled when the log is deinitialized.
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
        let (stream, continuation) = AsyncStream<Message>.makeStream(
            bufferingPolicy: .bufferingNewest(capacity)
        )
        self.continuation = continuation
        self.drainTask = Task {
            for await message in stream {
                await store.process(message)
            }
        }
    }

    deinit {
        continuation.finish()
        drainTask.cancel()
    }

    /// Record one event. Lock-free, non-blocking, safe from any thread.
    ///
    /// This is the hot-path API. It only yields the value onto the buffered
    /// stream; the actual ring write happens on the internal drain task. A burst
    /// past the consumer's pace drops the oldest pending events (per
    /// `.bufferingNewest`), never the caller.
    ///
    /// - Parameter event: The event to record.
    public nonisolated func record(_ event: DiagnosticEvent) {
        continuation.yield(.event(event))
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
    /// The clear is an ordered barrier in the same bounded stream as recorded
    /// events. It retries if a burst evicts the marker, so events yielded before
    /// the barrier cannot drain back into the new session after this returns.
    /// Recording itself remains non-blocking.
    public func clear(
        anchorWallNanos: UInt64 = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000_000)),
        anchorMonotonicNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) async {
        let barrierID = await store.reserveClearBarrier()
        while await !store.hasAppliedClearBarrier(barrierID) {
            switch continuation.yield(.clear(
                id: barrierID,
                anchorWallNanos: anchorWallNanos,
                anchorMonotonicNanos: anchorMonotonicNanos
            )) {
            case .enqueued, .dropped:
                await Task.yield()
            case .terminated:
                return
            @unknown default:
                return
            }
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
    private enum Message: Sendable {
        case event(DiagnosticEvent)
        case clear(id: UInt64, anchorWallNanos: UInt64, anchorMonotonicNanos: UInt64)
    }

    private actor Store {
        private var slots: [DiagnosticEvent?]
        private var head = 0
        private var filled = 0
        private var totalProcessed = 0
        private var nextClearBarrierID: UInt64 = 1
        private var appliedClearBarrierID: UInt64 = 0
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

        func process(_ message: Message) {
            switch message {
            case let .event(event):
                append(event)
            case let .clear(id, anchorWallNanos, anchorMonotonicNanos):
                guard id > appliedClearBarrierID else { return }
                clear(
                    anchorWallNanos: anchorWallNanos,
                    anchorMonotonicNanos: anchorMonotonicNanos
                )
                appliedClearBarrierID = id
            }
        }

        private func append(_ event: DiagnosticEvent) {
            slots[head] = event
            head = (head + 1) % capacity
            if filled < capacity {
                filled += 1
            }
            totalProcessed += 1
        }

        func count() -> Int {
            filled
        }

        func processedCount() -> Int {
            totalProcessed
        }

        func reserveClearBarrier() -> UInt64 {
            let id = nextClearBarrierID
            nextClearBarrierID &+= 1
            if nextClearBarrierID == 0 {
                nextClearBarrierID = 1
            }
            return id
        }

        func hasAppliedClearBarrier(_ id: UInt64) -> Bool {
            appliedClearBarrierID >= id
        }

        func clear(anchorWallNanos: UInt64, anchorMonotonicNanos: UInt64) {
            slots = Array(repeating: nil, count: capacity)
            head = 0
            filled = 0
            totalProcessed = 0
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
