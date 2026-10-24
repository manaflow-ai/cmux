public import CmuxNextDaemon
import os

extension DaemonService {
    /// After a command's reply on `connection`: waits until the store applied every event the daemon emitted
    /// before that reply, and says whether it did (``DaemonStore/appliedThrough(_:since:)``). Not held at once
    /// when `connection` is no longer this service's (another connection's sequence proves nothing about this
    /// command); not held when the connection lost `ready`, or ended or changed during the wait. A caller that
    /// reads the store for the command's result branches on it: only ``AppliedThroughReply/held`` lets it read
    /// the result as complete.
    ///
    /// The checked post-reply wait for commands sent through this service. Some older paths still read
    /// `connection.eventSequence()` and wait on the store themselves (`whenApplied`, the intents' barriers).
    ///
    /// - Parameters:
    ///   - connection: The connection that answered the command, captured where the command ran (never
    ///     ``connection`` read again after the reply).
    ///   - label: The command whose result the caller reads next; named in the log line when the wait does not
    ///     hold (a cancelled wait is not logged), so a read that may lack the result is visible, never silent.
    /// - Returns: Whether the store holds the command's events, and why not.
    public func appliedThroughReply(on connection: DaemonConnection, after label: String) async -> AppliedThroughReply {
        let result = await waitForReply(on: connection)
        switch result {
        case .held, .cancelled: break
        case .noSequence:
            logger.error("\(label, privacy: .public): the store did not catch up with the reply (the connection had no event sequence); reading it may miss the command's result")
        case .connectionChanged:
            logger.error("\(label, privacy: .public): the store did not catch up with the reply (the connection ended or changed); reading it may miss the command's result")
        }
        return result
    }

    private func waitForReply(on connection: DaemonConnection) async -> AppliedThroughReply {
        guard self.connection === connection else { return .connectionChanged }
        let epoch = store.connectionEpoch
        guard let sequence = await connection.eventSequence() else { return .noSequence }
        let held = await store.appliedThrough(sequence, since: epoch)
        if held, self.connection === connection { return .held }
        return Task.isCancelled ? .cancelled : .connectionChanged
    }

    /// Read-your-writes against the daemon: one round trip on the current connection, then waits until the
    /// store has applied every event the daemon emitted before that reply (and the session state is
    /// resolved). After it returns, the store holds every change the daemon committed before the call, from
    /// any client.
    ///
    /// - Throws: ``DaemonError/notConnected`` with no connection, or when it did not hold: the post-reply wait
    ///   did not hold (``appliedThroughReply(on:after:)``), or the connection changed after it
    ///   (``DaemonStore/connectionEpoch`` moved, a drop and reconnect of the same connection object included)
    ///   before the session state resolved; the request's error.
    /// - Returns: The store's applied sequence after the wait.
    @discardableResult
    public func appliedThroughSyncBarrier() async throws -> UInt64 {
        guard let connection else { throw DaemonError.notConnected }
        _ = try await connection.request(IdentifyRequest())
        guard await appliedThroughReply(on: connection, after: "sync barrier").isHeld else { throw DaemonError.notConnected }
        // sessionStateResolved also returns on a drop (and an internal reconnect of the same connection object).
        let epoch = store.connectionEpoch
        await store.sessionStateResolved()
        guard store.connectionEpoch == epoch, self.connection === connection else { throw DaemonError.notConnected }
        return store.appliedSequence
    }
}
