internal import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

extension CEFEngine {
    /// One snapshot of Chromium's histograms `names` (each one of the fork's allowlist): the samples since the
    /// previous snapshot, merged from every Chromium process. Starts nothing: before Chromium runs the answer is
    /// ``CEFHistogramHarvestError/notStarted``; with a fork or shim without the call, or in host mode,
    /// ``CEFHistogramHarvestError/unsupported``. Only the call runs on main; the fork answers on its thread pool.
    public func histogramSnapshot(names: [String]) async -> Result<[CEFHistogramDelta], CEFHistogramHarvestError> {
        let runtime = CEFRuntime.shared
        guard runtime.state == .ready, let shim = runtime.shim else { return .failure(.notStarted) }
        do {
            return try await withOnceContinuation { (continuation: OnceContinuation<Result<[CEFHistogramDelta], CEFHistogramHarvestError>,
                                                                                OnceContinuationError>) in
                let box = CEFHistogramSnapshotBox(continuation: continuation)
                // SAFETY: the +1 retain is the snapshot's context: the end call takes it back once
                // (CEFHistogramSnapshotBox.take), or the release below does when the snapshot did not start.
                let context = unsafe Unmanaged.passRetained(box).toOpaque()
                // SAFETY: the shim calls cefHistogramSnapshotCallback with `context` only after it returned 1, and
                // then ends with exactly one call whose name is NULL.
                let started = unsafe shim.histogramSnapshot(names, cefHistogramSnapshotCallback, context)
                guard started != 1 else { return }
                // SAFETY: no call back comes for a snapshot that did not start; this drops the +1 once.
                unsafe Unmanaged<CEFHistogramSnapshotBox>.fromOpaque(context).release()
                continuation.resume(returning: .failure(Self.histogramSnapshotError(started)))
            }
        } catch {
            return .failure(.abandoned)
        }
    }

    /// The error of a snapshot call that did not start (the shim's 0, -1, -2; nil: no export).
    nonisolated static func histogramSnapshotError(_ result: Int32?) -> CEFHistogramHarvestError {
        switch result {
        case 0: .notStarted
        case -1: .refused
        default: .unsupported
        }
    }
}

/// C entry of a histogram snapshot (`cmux_shim_histogram_fn`), on a Chromium thread-pool thread: a histogram's
/// delta is copied into the box (its buckets are valid only during the call); the end call (name NULL) resumes
/// the waiting snapshot.
let cefHistogramSnapshotCallback: CEFShimLibrary.HistogramFn = { context, name, sum, count, buckets, bucketCount in
    // SAFETY: only the context's address is read here; the box methods turn it back into the box.
    let address = unsafe UInt(bitPattern: context)
    guard let name = unsafe name else {
        CEFHistogramSnapshotBox.take(address)?.finish()
        return
    }
    guard let box = CEFHistogramSnapshotBox.peek(address) else { return }
    var copied: [CEFHistogramDelta.Bucket] = []
    if let buckets = unsafe buckets, bucketCount > 0 {
        copied.reserveCapacity(Int(bucketCount))
        for index in 0 ..< Int(bucketCount) {
            // SAFETY: the shim's buffer holds bucketCount (min, max, count) Int64 triples during this call.
            let triple = unsafe buckets + index * 3
            unsafe copied.append(CEFHistogramDelta.Bucket(minimum: triple[0], maximum: triple[1], count: triple[2]))
        }
    }
    // SAFETY: `name` is a NUL-terminated string valid during this call; String copies it.
    box.add(CEFHistogramDelta(name: unsafe String(cString: name), sum: sum, count: count, buckets: copied))
}

/// One snapshot in flight: the deltas so far and the waiting continuation, resumed once by the end call.
nonisolated final class CEFHistogramSnapshotBox: Sendable {
    private nonisolated struct State {
        var deltas: [CEFHistogramDelta] = []
        var continuation: OnceContinuation<Result<[CEFHistogramDelta], CEFHistogramHarvestError>, OnceContinuationError>?
    }

    private let state: Mutex<State>

    init(continuation: OnceContinuation<Result<[CEFHistogramDelta], CEFHistogramHarvestError>, OnceContinuationError>) {
        state = Mutex(State(continuation: continuation))
    }

    func add(_ delta: CEFHistogramDelta) {
        state.withLock { $0.deltas.append(delta) }
    }

    /// Resumes the snapshot with the deltas; a second end does nothing.
    func finish() {
        let (continuation, deltas) = state.withLock { current in
            let taken = (current.continuation, current.deltas)
            current.continuation = nil
            current.deltas = []
            return taken
        }
        continuation?.resume(returning: .success(deltas))
    }

    /// The box the context names, taking back the snapshot's retain (the end call only).
    static func take(_ address: UInt) -> CEFHistogramSnapshotBox? {
        // SAFETY: a nonzero address is the box histogramSnapshot retained, which the end call passes back once.
        guard let pointer = unsafe UnsafeRawPointer(bitPattern: address) else { return nil }
        // SAFETY: as above; this takes back the +1 exactly once.
        return unsafe Unmanaged<CEFHistogramSnapshotBox>.fromOpaque(pointer).takeRetainedValue()
    }

    /// The box the context names, while the snapshot's retain keeps it (the calls before the end).
    static func peek(_ address: UInt) -> CEFHistogramSnapshotBox? {
        // SAFETY: a nonzero address is the box histogramSnapshot retained; its +1 lasts until the end call.
        guard let pointer = unsafe UnsafeRawPointer(bitPattern: address) else { return nil }
        // SAFETY: as above.
        return unsafe Unmanaged<CEFHistogramSnapshotBox>.fromOpaque(pointer).takeUnretainedValue()
    }
}
