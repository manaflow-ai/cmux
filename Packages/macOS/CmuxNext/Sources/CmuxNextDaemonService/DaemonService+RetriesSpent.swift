public import CmuxNextDaemon
import CmuxNextWakeups

extension DaemonService {
    /// A remote machine's connection, as the service starts using it: requests refused for a pane
    /// still opening show their notice, and a reconnect that spent its timed retries marks the
    /// store (``DaemonStore/retriesSpent``), so its header reads offline instead of connecting
    /// forever and using the machine reconnects it (HQ #4877 G4). A delivery that lands after the
    /// link came back (``DaemonStore/noteRetriesSpent(_:)``) or after this connection was replaced
    /// or shut down changes nothing.
    func observeRemote(_ connection: DaemonConnection) async {
        await connection.observePaneNotReady(paneNotReadyReporter)
        await connection.observeRetriesSpent { [weak self, weak connection] in
            // One delivery to main each time the reconnect parks (after a failed attempt).
            MainDelivery().run {
                guard let self, let connection, self.connection === connection else { return }
                self.store.noteRetriesSpent(true)
            }
        }
    }
}
