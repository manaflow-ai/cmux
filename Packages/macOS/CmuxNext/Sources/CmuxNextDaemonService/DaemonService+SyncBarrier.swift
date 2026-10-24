public import CmuxNextDaemon
import os

extension DaemonService {
    /// After a command's reply on `connection`: waits until the store applied every event the daemon emitted
    /// before that reply, and says whether it did (``DaemonStore/appliedThrough(_:since:)``).
    ///
    /// When the wait on `connection` cannot hold (it is no longer this service's connection, it lost `ready`,
    /// or it ended or changed during the wait), the command still went through: the daemon committed it
    /// before its reply. So one barrier on the service's current connection decides instead: an `identify`
    /// round trip there, then the wait on the sequence that connection reads after it. That sequence bounds
    /// the command too, since a later connection's first snapshot holds every commit made before it. Only
    /// when that does not hold either (no current connection, its request fails, it ends too) is the result
    /// not held. A caller that reads the store for the command's result branches on it: only
    /// ``AppliedThroughReply/held`` lets it read the result as complete.
    ///
    /// The checked post-reply wait for commands sent through this service. Some older paths still read
    /// `connection.eventSequence()` and wait on the store themselves (`whenApplied`, the intents' barriers).
    ///
    /// - Parameters:
    ///   - connection: The connection that answered the command, captured where the command ran or read
    ///     before it (a later connection then decides through the barrier above).
    ///   - label: The command whose result the caller reads next; named in the log line when the wait does not
    ///     hold (a cancelled wait is not logged), so a read that may lack the result is visible, never silent.
    /// - Returns: Whether the store holds the command's events, and why not.
    public func appliedThroughReply(on connection: DaemonConnection, after label: String) async -> AppliedThroughReply {
        var result = await waitForReply(on: connection)
        if result == .noSequence || result == .connectionChanged {
            result = await waitForBarrier(else: result)
        }
        switch result {
        case .held, .cancelled: break
        case .noSequence:
            logger.error("\(label, privacy: .public): the store did not catch up with the reply (the connection had no event sequence); reading it may miss the command's result")
        case .connectionChanged:
            logger.error("\(label, privacy: .public): the store did not catch up with the reply (the connection ended or changed); reading it may miss the command's result")
        }
        return result
    }

    /// The wait on `connection`'s sequence after a reply on it: not held at once when it is not this service's
    /// connection (its sequence would bound another connection's events).
    private func waitForReply(on connection: DaemonConnection) async -> AppliedThroughReply {
        guard self.connection === connection else { return .connectionChanged }
        let epoch = store.connectionEpoch
        guard let sequence = await connection.eventSequence() else { return .noSequence }
        if await store.appliedThrough(sequence, since: epoch) { return .held }
        return Task.isCancelled ? .cancelled : .connectionChanged
    }

    /// One barrier on the service's current connection (an `identify` round trip, then ``waitForReply(on:)``):
    /// how a wait whose connection could not hold is decided. `first` is the answer when there is none to take.
    private func waitForBarrier(else first: AppliedThroughReply) async -> AppliedThroughReply {
        guard !Task.isCancelled else { return .cancelled }
        guard let current = connection else { return first }
        do {
            _ = try await current.request(IdentifyRequest())
        } catch {
            return Task.isCancelled ? .cancelled : first
        }
        return await waitForReply(on: current)
    }

    /// Read-your-writes against the daemon: one round trip on the current connection, then waits until the
    /// store has applied every event the daemon emitted before that reply (and the session state is
    /// resolved). After it returns, the store holds every change the daemon committed before the call, from
    /// any client.
    ///
    /// - Throws: ``DaemonError/notConnected`` with no connection, or when it did not hold: the post-reply wait
    ///   did not hold (``appliedThroughReply(on:after:)``), or the session state did not resolve on the same
    ///   connection (``DaemonStore/sessionStateResolved()`` false, or ``DaemonStore/connectionEpoch`` moved: a
    ///   drop and reconnect of the same connection object included); the request's error.
    /// - Returns: The store's applied sequence after the wait.
    @discardableResult
    public func appliedThroughSyncBarrier() async throws -> UInt64 {
        guard let connection else { throw DaemonError.notConnected }
        _ = try await connection.request(IdentifyRequest())
        guard await appliedThroughReply(on: connection, after: "sync barrier").isHeld else { throw DaemonError.notConnected }
        // Not resolved when the connection changed or ended first (a drop, a reconnect of the same connection
        // object, a run ended by close(), a connection marked failed): the store may lack the session state.
        let epoch = store.connectionEpoch
        guard await store.sessionStateResolved(), store.connectionEpoch == epoch else { throw DaemonError.notConnected }
        return store.appliedSequence
    }
}
