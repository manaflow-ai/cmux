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

    /// The continuation the hot path yields onto. `.bufferingNewest(capacity)`
    /// drops the oldest pending event if the consumer falls behind, so a burst
    /// can never block the recorder or grow unboundedly.
    private let continuation: AsyncStream<DiagnosticEvent>.Continuation

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
        anchorWallNanos: UInt64 = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000_000)),
        anchorMonotonicNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.capacity = capacity
        self.buildStamp = buildStamp
        let store = Store(
            capacity: capacity,
            buildStamp: buildStamp,
            anchorWallNanos: anchorWallNanos,
            anchorMonotonicNanos: anchorMonotonicNanos
        )
        self.store = store
        let (stream, continuation) = AsyncStream<DiagnosticEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(capacity)
        )
        self.continuation = continuation
        self.drainTask = Task {
            for await event in stream {
                await store.append(event)
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
        continuation.yield(event)
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

    /// The current number of retained events.
    public func count() async -> Int {
        await store.count()
    }

    /// The total number of events the drain task has processed since creation.
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
    private actor Store {
        private var slots: [DiagnosticEvent?]
        private var head = 0
        private var filled = 0
        private var totalProcessed = 0
        private let capacity: Int
        private let buildStamp: String
        private let anchorWallNanos: UInt64
        private let anchorMonotonicNanos: UInt64

        init(
            capacity: Int,
            buildStamp: String,
            anchorWallNanos: UInt64,
            anchorMonotonicNanos: UInt64
        ) {
            // A zero/negative capacity would make a 0-length ring; clamp to 1 so
            // append always has a slot.
            let clamped = max(1, capacity)
            self.capacity = clamped
            self.buildStamp = buildStamp
            self.anchorWallNanos = anchorWallNanos
            self.anchorMonotonicNanos = anchorMonotonicNanos
            self.slots = Array(repeating: nil, count: clamped)
        }

        func append(_ event: DiagnosticEvent) {
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

        func export() -> Data {
            var out = "cmuxdiag v1"
            out += " anchorWallNs=\(anchorWallNanos)"
            out += " anchorMonoNs=\(anchorMonotonicNanos)"
            out += " count=\(filled)"
            if !buildStamp.isEmpty {
                out += " build=\(buildStamp)"
            }
            out += "\n"
            for event in orderedEvents() {
                out += "\(event.tNanos),\(event.code.rawValue)"
                out += ",\(Self.field(event.surface))"
                out += ",\(Self.field(event.ms))"
                out += ",\(Self.field(event.a))"
                out += ",\(Self.field(event.b))"
                out += ",\(Self.field(event.c))"
                out += "\n"
            }
            return Data(out.utf8)
        }

        /// Render an optional integer field: empty when absent, decimal when set.
        private static func field(_ value: (some BinaryInteger)?) -> String {
            guard let value else { return "" }
            return String(value)
        }
    }
}
