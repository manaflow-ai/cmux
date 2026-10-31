public import CmuxNextDaemon

extension DaemonService {
    /// A remote machine's connection, as the service starts using it: requests refused for a pane
    /// still opening show their notice, and a reconnect that spent its timed retries marks the
    /// store (``DaemonStore/retriesSpent``), so its header reads offline instead of connecting
    /// forever (HQ #4877 G4). A hop that lands after the link came back
    /// (``DaemonStore/noteRetriesSpent(_:)``) or after this connection was replaced or shut down
    /// (a Reconnect's restart) changes nothing.
    func observeRemote(_ connection: DaemonConnection) async {
        await connection.observePaneNotReady(paneNotReadyReporter)
        await connection.observeRetriesSpent { [weak self, weak connection] in
            // task-owner: one hop to main per failed attempt past the budget; nothing to cancel
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                self.store.noteRetriesSpent(true)
            }
        }
    }
}
