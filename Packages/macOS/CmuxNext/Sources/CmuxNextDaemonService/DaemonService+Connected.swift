import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextWakeups

extension DaemonService {
    /// This daemon's connection once it has one, within `bound`: woken by the connection itself,
    /// never by polling. Throws `DaemonError.notConnected` past the bound, and stops on cancellation.
    public func connected(within bound: Duration, owner: String) async throws -> DaemonConnection {
        if let connection { return connection }
        // The first of the connection appearing, the bound and cancellation resumes the wait once
        // (no task group waits for a loser).
        let outcome = FirstOutcome<Bool>()
        let watch = Task { @MainActor in
            for await ready in ObservationStream({ self.connection != nil }) where ready {
                outcome.resolve(true)
                return
            }
        }
        let timer = DemandTimer(owner: owner)
        timer.schedule(after: bound) { outcome.resolve(false) }
        let ready = await withTaskCancellationHandler {
            await outcome.value()
        } onCancel: {
            outcome.resolve(false)
        }
        watch.cancel()
        timer.cancel()
        try Task.checkCancellation()
        guard ready, let connection else { throw DaemonError.notConnected }
        return connection
    }
}
