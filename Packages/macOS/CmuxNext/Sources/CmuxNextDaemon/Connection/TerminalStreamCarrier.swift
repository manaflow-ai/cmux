/// The ready control transport terminal views stream on, with its daemon's identity.
struct TerminalStreamCarrier: Sendable {
    let transport: LineTransport
    let identity: DaemonIdentity

    /// How a view of a connection attaches.
    enum Route: Sendable {
        /// As a stream on the connection's control transport.
        case stream(TerminalStreamCarrier)
        /// On a connection of its own to this daemon: the connection does not stream terminals, or its
        /// daemon does not offer the grant.
        case ownConnection(DaemonEndpoint)
    }

    /// How long a view of a streaming connection waits for it to be ready (a first connect, a reconnect).
    static let readyWait: Duration = .seconds(10)

    /// How a view of `connection` attaches. A connection that streams terminals
    /// (``DaemonConnectionConfiguration/terminalStreams``) is waited for, up to `limit`, until it is ready on an
    /// open transport, as the attach machine reattaches on the connection's next epoch; only a daemon without the
    /// grant sends the view to a connection of its own. Throws `notConnected` when no such epoch comes in time.
    static func route(for connection: DaemonConnection, within limit: Duration = readyWait) async throws(DaemonError) -> Route {
        guard connection.configuration.streamsTerminals else {
            guard let endpoint = await connection.endpoint else { throw .notConnected }
            return .ownConnection(endpoint)
        }
        var after: UInt64?
        // Twice at most: a ready epoch whose transport closed already has its close on the way to the
        // connection, which then reconnects; the wait is for the epoch after it.
        for _ in 0..<2 {
            guard await connection.untilReady(after: after, within: limit) else { break }
            guard let epoch = await currentEpoch(connection) else { continue }
            guard epoch.ready.identity.supports(TerminalAttachment.streamsCapability) else {
                return .ownConnection(epoch.endpoint)
            }
            guard epoch.ready.transport.isClosed else {
                return .stream(TerminalStreamCarrier(transport: epoch.ready.transport, identity: epoch.ready.identity))
            }
            after = epoch.ready.serial
        }
        throw .notConnected
    }

    /// The connection's ready epoch and the endpoint it reached, read in one turn of the connection.
    private static func currentEpoch(_ connection: isolated DaemonConnection)
        -> (ready: DaemonReadyConnection, endpoint: DaemonEndpoint)? {
        guard let ready = connection.ready, let endpoint = connection.endpoint else { return nil }
        return (ready, endpoint)
    }
}
