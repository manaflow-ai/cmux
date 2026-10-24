public import CmuxNextDaemon

extension DaemonService {
    /// Read-your-writes against the daemon: one round trip on the current connection, then waits until the
    /// store has applied every event the daemon emitted before that reply (and the session state is
    /// resolved). After it returns, the store holds every change the daemon committed before the call, from
    /// any client.
    ///
    /// - Throws: ``DaemonError/notConnected`` with no connection; when the connection has no event
    ///   sequence after the reply (it lost `ready`: nothing proves the store caught up); or when the wait
    ///   ended without the store reaching that sequence (the connection changed, or its state did with the
    ///   same connection object: the store may lack what the old events carried); the request's error.
    /// - Returns: The store's applied sequence after the wait.
    @discardableResult
    public func appliedThroughSyncBarrier() async throws -> UInt64 {
        guard let connection else { throw DaemonError.notConnected }
        _ = try await connection.request(IdentifyRequest())
        guard let sequence = await connection.eventSequence() else { throw DaemonError.notConnected }
        await store.applied(through: sequence)
        await store.sessionStateResolved()
        // `applied(through:)` also returns on a connection-state change: only a store that reached the
        // sequence holds every event the daemon emitted before the reply.
        guard self.connection === connection, store.appliedSequence >= sequence else { throw DaemonError.notConnected }
        return store.appliedSequence
    }
}
