public import CmuxNextDaemon

extension DaemonService {
    /// A remote machine's connection, as the service starts using it: requests refused for a pane
    /// still opening show their notice, and a reconnect that spent its timed retries marks the
    /// store (``DaemonStore/retriesSpent``), so its header reads offline instead of connecting
    /// forever (HQ #4877 G4). A hop that lands after the link came back changes nothing
    /// (``DaemonStore/noteRetriesSpent(_:)``).
    func observeRemote(_ connection: DaemonConnection) async {
        await connection.observePaneNotReady(paneNotReadyReporter)
        let store = store
        await connection.observeRetriesSpent {
            // task-owner: one hop to main per failed attempt past the budget; nothing to cancel
            Task { @MainActor in store.noteRetriesSpent(true) }
        }
    }
}
