public import CmuxNextDaemon

extension DaemonService {
    /// Read-your-writes against the daemon: one round trip on the current connection, then waits until the
    /// store has applied every event the daemon emitted before that reply (and the session state is
    /// resolved). After it returns, the store holds every change the daemon committed before the call, from
    /// any client.
    ///
    /// - Throws: ``DaemonError/notConnected`` with no connection, or when the connection changed during
    ///   the wait (the new connection's store may lack what the old one's events carried); the request's error.
    /// - Returns: The store's applied sequence after the wait.
    @discardableResult
    public func appliedThroughSyncBarrier() async throws -> UInt64 {
        guard let connection else { throw DaemonError.notConnected }
        _ = try await connection.request(IdentifyRequest())
        await store.applied(through: await connection.eventSequence())
        await store.sessionStateResolved()
        guard self.connection === connection else { throw DaemonError.notConnected }
        return store.appliedSequence
    }
}
