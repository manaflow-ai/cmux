public import CmuxNextDaemon
import os

extension DaemonService {
    /// After a command's reply on `connection`: waits until the store applied every event the daemon emitted
    /// before that reply, and says whether it did (``DaemonStore/appliedThrough(_:since:)``). False when the
    /// connection lost `ready`, dropped during the wait, or is no longer this service's: the store may lack
    /// what the command changed, so a caller that reads the store for the result must not take it as complete.
    ///
    /// The one post-reply wait: a caller never reads `connection.eventSequence()` and waits on the store by
    /// itself.
    ///
    /// - Parameter connection: The connection that answered the command.
    /// - Returns: Whether the store holds the command's events.
    /// - Parameter label: The command whose result the caller reads next; named in the log line when the wait
    ///   does not hold, so a read that may lack the result is visible, never silent.
    @discardableResult
    public func appliedThroughReply(on connection: DaemonConnection, after label: String) async -> Bool {
        let epoch = store.connectionEpoch
        let sequence = await connection.eventSequence()
        let held = await store.appliedThrough(sequence, since: epoch)
        guard held, self.connection === connection else {
            logger.error("\(label, privacy: .public): the store did not catch up with the reply (\(sequence == nil ? "no event sequence" : "the connection changed", privacy: .public)); reading it may miss the command's result")
            return false
        }
        return true
    }

    /// Read-your-writes against the daemon: one round trip on the current connection, then waits until the
    /// store has applied every event the daemon emitted before that reply (and the session state is
    /// resolved). After it returns, the store holds every change the daemon committed before the call, from
    /// any client.
    ///
    /// - Throws: ``DaemonError/notConnected`` with no connection, or when the wait did not hold
    ///   (``appliedThroughReply(on:after:)``: no event sequence after the reply, a drop during the wait, another
    ///   connection now); the request's error.
    /// - Returns: The store's applied sequence after the wait.
    @discardableResult
    public func appliedThroughSyncBarrier() async throws -> UInt64 {
        guard let connection else { throw DaemonError.notConnected }
        _ = try await connection.request(IdentifyRequest())
        guard await appliedThroughReply(on: connection, after: "sync barrier") else { throw DaemonError.notConnected }
        await store.sessionStateResolved()
        guard self.connection === connection else { throw DaemonError.notConnected }
        return store.appliedSequence
    }
}
