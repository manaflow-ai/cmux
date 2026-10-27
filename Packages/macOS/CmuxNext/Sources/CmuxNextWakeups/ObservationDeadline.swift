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

    /// - Parameter owner: The limit timer's name in the wakeup ledger.
    public init(owner: String) {
        // timer-class-allow: the deadline half of this wait primitive; its action only ends the wait
        timer = DemandTimer(owner: owner)
    }

    /// Returns once `condition` holds or `limit` passed, whichever is first; at once when it holds already.
    ///
    /// - Parameters:
    ///   - condition: Read with Observation tracking on the main actor; re-read on each change of what it read.
    ///   - limit: The longest wait.
    public func until(_ condition: @escaping @MainActor @Sendable () -> Bool, limit: Duration) async {
        try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
            self.continuation = continuation
            // task-owner: this wait (cancelled in finish); event-driven (Observation)
            // main-hop-allow: the observation half of this wait primitive: a main-actor loop that only ends the wait
            watch = Task { @MainActor [weak self] in
                // view-observation-allow: the wait primitive itself; it applies nothing, it only ends the wait
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
