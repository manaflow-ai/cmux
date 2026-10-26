public import CmuxNextInputCore
internal import CmuxNextCompat

/// The off-main half of input latency: folds the closed-slot batches the input ring's writer
/// hands over into an ``InputLatencyLedger`` (histograms per kind x target x entrypoint x
/// presentation source, Chrome's scroll jank formula) on its own reader, as ``ActionBudgetReporter``
/// does for action runs.
///
/// ``submit(_:)`` never waits and may be called from any thread, the main one included: once per
/// batch (half a ring of slots), one bounded stream yield and one atomic add, the same hand-off as
/// `ActionBudgetMonitor.batches()`; the folding runs on the reader. The stream holds
/// ``defaultBufferedBatches`` batches for a slow reader; a batch that does not fit is dropped and
/// its slots counted in the report's `slots_dropped`, so memory never grows. Values only: no UI
/// type reaches it.
///
/// ```swift
/// let reporter = InputLatencyReporter()
/// Task.detached(priority: .utility) { await reporter.run() }
/// reporter.submit(InputLatencyBatch(slots: ring.takeBatch(), vsyncNanos: 8_333_333))
/// let report = await reporter.snapshot()
/// ```
public final class InputLatencyReporter: Sendable {
    /// Batches the stream holds for a slow reader unless told otherwise.
    public static let defaultBufferedBatches = 4

    private let store = Store()
    private let stream: AsyncStream<InputLatencyBatch>
    private let continuation: AsyncStream<InputLatencyBatch>.Continuation
    /// Batches handed over that the reader will fold (enqueued, minus those a later batch pushed out).
    private let accepted = Atomic<UInt64>(0)
    /// Slots lost in the hand-off: batches pushed out of a full stream or sent after ``finish()``.
    private let handOffDropped = Atomic<UInt64>(0)
    private let started = Atomic<Bool>(false)

    /// A reporter whose stream holds `bufferedBatches` batches (at least 1).
    public init(bufferedBatches: Int = InputLatencyReporter.defaultBufferedBatches) {
        let (stream, continuation) = AsyncStream<InputLatencyBatch>.makeStream(bufferingPolicy: .bufferingNewest(max(1, bufferedBatches)))
        self.stream = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    /// Folds batches until ``finish()``. Call it once, from a utility-priority task the owner
    /// keeps; a second call returns at once.
    public func run() async {
        guard !started.exchange(true, ordering: .relaxed) else { return }
        for await batch in stream { await store.fold(batch) }
        await store.finishReading()
    }

    /// Hands one batch to the reader without waiting.
    ///
    /// - Parameter batch: Slots the ring handed over, the refresh interval to judge scroll frames
    ///   against, and the slots lost before them.
    public func submit(_ batch: InputLatencyBatch) {
        let result = continuation.yield(batch)
        if case .enqueued = result {
            accepted.wrappingAdd(1, ordering: .releasing)
        } else if case .dropped(let lost) = result {
            // The stream keeps the newest batches: `lost` is the oldest one, pushed out by `batch`.
            handOffDropped.wrappingAdd(UInt64(truncatingIfNeeded: lost.slots.count) &+ lost.droppedBefore, ordering: .relaxed)
        } else {
            handOffDropped.wrappingAdd(UInt64(truncatingIfNeeded: batch.slots.count) &+ batch.droppedBefore, ordering: .relaxed)
        }
    }

    /// Ends the stream: ``run()`` folds the batches already handed over and returns, and later
    /// batches count as dropped.
    public func finish() {
        continuation.finish()
    }

    /// The report now: every batch ``submit(_:)`` accepted before the call is folded in first, so
    /// it waits for ``run()`` to read them (or to end after ``finish()``).
    public func snapshot() async -> InputLatencySnapshot {
        let target = accepted.load(ordering: .acquiring)
        var snapshot = await store.snapshot(afterFolding: target)
        snapshot.slotsDropped &+= handOffDropped.load(ordering: .relaxed)
        return snapshot
    }

    /// The ledger and the reader's progress, on their own executor.
    private actor Store {
        private var ledger = InputLatencyLedger()
        private var folded: UInt64 = 0
        /// The reader has not ended: accepted batches will still be folded.
        private var reading = true
        private var waiters: [(target: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

        func fold(_ batch: InputLatencyBatch) {
            ledger.fold(batch)
            folded &+= 1
            resumeWaiters { $0 <= folded }
        }

        func finishReading() {
            reading = false
            resumeWaiters { _ in true }
        }

        func snapshot(afterFolding target: UInt64) async -> InputLatencySnapshot {
            while reading, folded < target {
                await withCheckedContinuation { continuation in waiters.append((target, continuation)) }
            }
            return ledger.snapshot
        }

        private func resumeWaiters(where ready: (UInt64) -> Bool) {
            guard !waiters.isEmpty else { return }
            var waiting: [(target: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
            for waiter in waiters {
                if ready(waiter.target) { waiter.continuation.resume() } else { waiting.append(waiter) }
            }
            waiters = waiting
        }
    }
}
