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
/// its slots counted in the report's `slots_dropped` (its producer drops arrive with the next
/// batch, as ``InputLatencyBatch/droppedTotal`` is cumulative), so memory never grows. Values only: no UI
/// type reaches it.
///
/// ```swift
/// let reporter = InputLatencyReporter()
/// Task.detached(priority: .utility) { await reporter.run() }
/// let slots = ring.takeBatch()
/// reporter.submit(InputLatencyBatch(slots: slots, vsyncNanos: 8_333_333,
///                                   droppedTotal: ring.droppedCount &+ table.droppedCount))
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
    ///   against, and the producer's cumulative lost-slot count.
    public func submit(_ batch: InputLatencyBatch) {
        let result = continuation.yield(batch)
        if case .enqueued = result {
            accepted.wrappingAdd(1, ordering: .releasing)
        } else if case .dropped(let lost) = result {
            // The stream keeps the newest batches: `lost` is the oldest one, pushed out by `batch`.
            handOffDropped.wrappingAdd(UInt64(truncatingIfNeeded: lost.slots.count), ordering: .relaxed)
        } else {
            handOffDropped.wrappingAdd(UInt64(truncatingIfNeeded: batch.slots.count), ordering: .relaxed)
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

    /// Starts the report over (`debug.input reset`): every batch ``submit(_:)`` accepted before the
    /// call is folded first, then the histograms, the counts and the hand-off losses go back to zero.
    public func reset() async {
        let target = accepted.load(ordering: .acquiring)
        await store.reset(afterFolding: target)
        _ = handOffDropped.exchange(0, ordering: .relaxed)
    }

    /// Starts or stops the opt-in field report's own ledger (hang reports on or off). While on,
    /// every batch is folded into it too, and ``takeFieldReport()`` hands out its counts since the
    /// last take, so `debug.input` and its reset never change what the report says. Off drops it.
    /// Every batch accepted before the call is folded first, so none of them counts in the field.
    public func setFieldReport(_ on: Bool) async {
        let target = accepted.load(ordering: .acquiring)
        await store.setField(on, afterFolding: target)
    }

    /// The field ledger's counts since it started or since the last take, every accepted batch
    /// folded first; the field ledger starts over. Nil while the field report is off.
    public func takeFieldReport() async -> InputLatencySnapshot? {
        let target = accepted.load(ordering: .acquiring)
        return await store.takeField(afterFolding: target)
    }

    /// The ledger and the reader's progress, on their own executor.
    private actor Store {
        private var ledger = InputLatencyLedger()
        /// The opt-in field report's ledger, nil while it is off.
        private var field: InputLatencyLedger?
        private var folded: UInt64 = 0
        /// The reader has not ended: accepted batches will still be folded.
        private var reading = true
        private var waiters: [(target: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

        func fold(_ batch: InputLatencyBatch) {
            ledger.fold(batch)
            field?.fold(batch)
            folded &+= 1
            resumeWaiters { $0 <= folded }
        }

        func finishReading() {
            reading = false
            resumeWaiters { _ in true }
        }

        func snapshot(afterFolding target: UInt64) async -> InputLatencySnapshot {
            await waitFolded(target)
            return ledger.snapshot
        }

        func reset(afterFolding target: UInt64) async {
            await waitFolded(target)
            ledger.reset()
        }

        func setField(_ on: Bool, afterFolding target: UInt64) async {
            await waitFolded(target)
            guard on else {
                field = nil
                return
            }
            guard field == nil else { return }
            // A copy of the main ledger, emptied: it keeps the producer's drop baseline, so the
            // first batch adds only the slots lost after the start.
            var started = ledger
            started.reset()
            field = started
        }

        func takeField(afterFolding target: UInt64) async -> InputLatencySnapshot? {
            await waitFolded(target)
            guard var taken = field else { return nil }
            let snapshot = taken.snapshot
            taken.reset()
            field = taken
            return snapshot
        }

        private func waitFolded(_ target: UInt64) async {
            while reading, folded < target {
                await withCheckedContinuation { continuation in waiters.append((target, continuation)) }
            }
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
