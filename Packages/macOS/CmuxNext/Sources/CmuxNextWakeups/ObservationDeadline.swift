import CmuxNextCompat

/// Waits until `condition` holds (an Observation of a store) or `limit`
/// passes on a `DemandTimer`, whichever comes first; resumes once. An undo
/// that must wait for the daemon's records to arrive uses it (moved out of
/// CmuxNextApp, code-quality.md SW14).
@MainActor
public final class ObservationDeadline {
    private var continuation: CheckedContinuation<Void, Never>?
    private var watch: Task<Void, Never>?
    private let timer: DemandTimer

    /// - Parameter owner: The limit timer's name in the wakeup ledger.
    public init(owner: String) {
        timer = DemandTimer(owner: owner)
    }

    /// Returns once `condition` holds or `limit` passed, whichever is first; at once when it holds already.
    ///
    /// - Parameters:
    ///   - condition: Read with Observation tracking on the main actor; re-read on each change of what it read.
    ///   - limit: The longest wait.
    public func until(_ condition: @escaping @MainActor @Sendable () -> Bool, limit: Duration) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            // task-owner: this wait (cancelled in finish); event-driven (Observation)
            watch = Task { @MainActor [weak self] in
                for await done in ObservationStream(condition) where done { break }
                self?.finish()
            }
            timer.schedule(after: limit) { @MainActor [weak self] in self?.finish() }
        }
    }

    private func finish() {
        watch?.cancel()
        timer.cancel()
        continuation?.resume()
        continuation = nil
    }
}
