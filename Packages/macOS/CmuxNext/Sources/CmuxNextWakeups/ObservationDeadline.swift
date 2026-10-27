import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Waits until `condition` holds (an Observation of a store) or `limit`
/// passes on a `DemandTimer`, whichever comes first; resumes once. An undo
/// that must wait for the daemon's records to arrive uses it (moved out of
/// CmuxNextApp, code-quality.md SW14).
@MainActor
public final class ObservationDeadline {
    private var continuation: OnceContinuation<Void, OnceContinuationError>?
    private var watch: Task<Void, Never>?
    private let timer: DemandTimer

    public init(owner: String) {
        timer = DemandTimer(owner: owner)
    }

    public func until(_ condition: @escaping @MainActor @Sendable () -> Bool, limit: Duration) async {
        try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
            self.continuation = continuation
            // task-owner: this wait (cancelled in finish); event-driven (Observation)
            watch = Task { @MainActor [weak self] in
                for await done in ObservationStream(condition) where done { break }
                self?.finish()
            }
            timer.scheduleOnMain(after: limit) { [weak self] in self?.finish() }
        }
    }

    private func finish() {
        watch?.cancel()
        timer.cancel()
        continuation?.resume(returning: ())
        continuation = nil
    }
}
