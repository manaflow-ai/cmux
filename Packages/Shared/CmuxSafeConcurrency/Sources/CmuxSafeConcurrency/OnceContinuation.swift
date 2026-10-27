/// Why a ``OnceContinuation`` ended without a result from its producer.
public enum OnceContinuationError: Error, Sendable, Equatable {
    /// The last reference to the continuation went away before anything resumed it: the producer dropped its
    /// callback. Without this the waiting task would hang for ever.
    case abandoned
    /// The waiting task was cancelled, and the wait was made with ``OnceContinuationCancellation/cancellable``.
    /// ``withOnceThrowingContinuation(isolation:cancellation:faults:function:fileID:line:_:)`` throws it as
    /// `CancellationError`; a typed wait hands it to its `failingWith` mapping.
    case cancelled

    /// The error ``withOnceThrowingContinuation(isolation:cancellation:faults:function:fileID:line:_:)`` throws
    /// for this ending: `CancellationError` for a cancelled wait (what `catch is CancellationError` expects),
    /// this error otherwise.
    public var thrown: any Error {
        switch self {
        case .abandoned:
            return self
        case .cancelled:
            return CancellationError()
        }
    }
}

/// Whether cancelling the waiting task ends a ``OnceContinuation`` wait.
public enum OnceContinuationCancellation: Sendable, Equatable {
    /// Cancellation does not end the wait; only the producer's resume (or abandonment) does. A raw
    /// `withCheckedContinuation` behaves so, which is why it is the default.
    case notCancellable
    /// Cancellation ends the wait at once: `CancellationError` from
    /// ``withOnceThrowingContinuation(isolation:cancellation:faults:function:fileID:line:_:)``, the mapped
    /// ``OnceContinuationError/cancelled`` from a typed wait. The producer's first resume after it is a no-op
    /// and no fault; a second is a double resume and reports one. Choose it only where the producer's work is
    /// cancelled too, or is harmless to finish unobserved.
    case cancellable
}

/// A continuation that resumes its waiting task exactly once, whatever its producer does: the first resume
/// wins; a second is a no-op that returns false and reports a fault (a raw `CheckedContinuation` stops the
/// process there); a continuation dropped without a resume resumes the task with
/// ``OnceContinuationError/abandoned`` (a raw one leaks the task) and reports a fault.
///
/// Chromium's `base::OnceCallback` (base/functional/callback.h) is the model: one run, consumed by it, and
/// its destruction without a run is defined, never a hang. Make one with
/// ``withOnceContinuation(isolation:faults:function:fileID:line:_:)``,
/// ``withOnceThrowingContinuation(isolation:cancellation:faults:function:fileID:line:_:)`` or
/// ``withOnceContinuation(isolation:cancellation:failingWith:faults:function:fileID:line:_:)``.
public final class OnceContinuation<Success: Sendable, Failure: Error>: Sendable {
    typealias Raw = CheckedContinuation<Result<Success, Failure>, Never>

    /// Where the continuation is in its one life. Only `waiting` holds the raw continuation, so it can be
    /// resumed only on the one transition out of `waiting`. A cancelled wait still records the producer's
    /// resume (`cancelledThenResumed`), so a second producer resume after a cancel is a fault as it is
    /// without one.
    enum Phase: Sendable {
        case waiting(Raw)
        case resumed
        case cancelled
        case cancelledThenResumed
    }

    private let phase: Mutex<Phase>
    private let ending: @Sendable (OnceContinuationError) -> Failure
    private let faults: OnceContinuationFaultReporter
    private let site: OnceContinuationFault.Site

    init(
        _ raw: Raw,
        ending: @escaping @Sendable (OnceContinuationError) -> Failure,
        faults: OnceContinuationFaultReporter,
        site: OnceContinuationFault.Site
    ) {
        phase = Mutex(.waiting(raw))
        self.ending = ending
        self.faults = faults
        self.site = site
    }

    /// Resumes the waiting task with `value`. Returns false, without a resume, when the continuation already
    /// ended: a second producer resume also reports a fault; the first resume after a cancelled wait does not.
    @discardableResult
    public func resume(returning value: Success) -> Bool {
        resume(with: .success(value))
    }

    /// Resumes the waiting task by throwing `error`; returns as ``resume(returning:)`` does.
    @discardableResult
    public func resume(throwing error: Failure) -> Bool {
        resume(with: .failure(error))
    }

    /// Resumes the waiting task with `result`; returns as ``resume(returning:)`` does.
    @discardableResult
    public func resume(with result: Result<Success, Failure>) -> Bool {
        let previous: Phase = phase.withLock { current in
            let previous = current
            switch current {
            case .waiting:
                current = .resumed
            case .cancelled:
                current = .cancelledThenResumed
            case .resumed, .cancelledThenResumed:
                break
            }
            return previous
        }
        switch previous {
        case .waiting(let raw):
            raw.resume(returning: result)
            return true
        case .cancelled:
            return false
        case .resumed, .cancelledThenResumed:
            faults.report(OnceContinuationFault(.resumedTwice, at: site))
            return false
        }
    }

    /// Ends a cancellable wait with ``OnceContinuationError/cancelled``; nothing when it already ended.
    func cancel() {
        if case .waiting(let raw) = end(as: .cancelled) {
            raw.resume(returning: .failure(ending(.cancelled)))
        }
    }

    /// Moves to `next` when the continuation is waiting, and returns the phase it was in. The raw
    /// continuation leaves the lock in the returned phase and is resumed after the unlock.
    private func end(as next: Phase) -> Phase {
        phase.withLock { current in
            let previous = current
            if case .waiting = current {
                current = next
            }
            return previous
        }
    }

    deinit {
        if case .waiting(let raw) = end(as: .resumed) {
            raw.resume(returning: .failure(ending(.abandoned)))
            faults.report(OnceContinuationFault(.abandoned, at: site))
        }
    }
}
