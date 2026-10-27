/// Page streams for a daemon without page streams on one connection (before p05-ipc-103): each
/// stream is its own `page_relay` connection whose `client-hello` names the page, so the daemon
/// still derives origin `page` for every call on it. The stream's epoch is that connection's
/// first daemon and hello id; when the connection drops and comes back (a new hello id) the
/// stream has ended, so a token bound to the old id is never sent on the new one.
public final class PageRelayDedicatedStreams: PageRelayStreamOpening {
    private let clientName: String
    private let retryWake: RetryWake?
    private let endpointProvider: DaemonConnection.EndpointProvider

    public init(clientName: String, retryWake: RetryWake?, endpointProvider: @escaping DaemonConnection.EndpointProvider) {
        self.clientName = clientName
        self.retryWake = retryWake
        self.endpointProvider = endpointProvider
    }

    public func openStream(page: String) async throws -> any PageRelayStream {
        let relayIdentity = PageRelayIdentity(page: page)
        let configuration = DaemonConnection.Configuration(
            clientName: clientName, requiredCapabilities: [], retryWake: retryWake,
            terminalEnvironment: nil, role: .pageRelay, relayIdentity: relayIdentity)
        let connection = DaemonConnection(configuration: configuration, endpointProvider: endpointProvider)
        // A dedicated stream sends requests only: its page's events are dropped as they come, so they
        // neither buffer nor fill the event stream's byte bound, past which the reader would wait.
        connection.discardEvents()
        let reached: DaemonIdentity
        do {
            reached = try await connection.start()
        } catch {
            await connection.close()
            throw error
        }
        guard let connectionID = relayIdentity.connectionID else {
            await connection.close()
            throw DaemonError.notConnected
        }
        let epoch = PageRelayEpoch(pid: reached.pid, generation: reached.generation, connectionID: connectionID)
        return DedicatedStream(page: page, epoch: epoch, connection: connection, relayIdentity: relayIdentity)
    }

    /// One page on its own connection.
    private final class DedicatedStream: PageRelayStream {
        let page: String
        let epoch: PageRelayEpoch
        private let connection: DaemonConnection
        private let relayIdentity: PageRelayIdentity

        init(page: String, epoch: PageRelayEpoch, connection: DaemonConnection, relayIdentity: PageRelayIdentity) {
            self.page = page
            self.epoch = epoch
            self.connection = connection
            self.relayIdentity = relayIdentity
        }

        var isOpen: Bool {
            get async {
                guard await connection.isReady, let identity = await connection.identity,
                      epoch.serves(pid: identity.pid, generation: identity.generation) else { return false }
                return relayIdentity.connectionID == epoch.connectionID
            }
        }

        func send(operation: String, params: [String: JSONValue], idempotencyKey: String?,
                  origin: JSONValue) async throws -> JSONValue {
            guard await isOpen else { throw DaemonError.connectionClosed(reason: "page stream \(page) ended") }
            return try await ResourceRelayClient(connection: connection).send(
                operation: operation, params: params, idempotencyKey: idempotencyKey, origin: origin)
        }

        func close() async {
            await connection.close()
        }
    }
}
