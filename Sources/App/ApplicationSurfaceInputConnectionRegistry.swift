import CmuxControlSocket

@MainActor
final class ApplicationSurfaceInputConnectionRegistry {
    private let transport: SocketTransport
    private var connections: [String: PersistentSocketLineConnection] = [:]

    init(transport: SocketTransport) {
        self.transport = transport
    }

    func makeConnection() -> PersistentSocketLineConnection {
        PersistentSocketLineConnection(transport: transport)
    }

    func register(
        _ connection: PersistentSocketLineConnection,
        for sessionID: String
    ) {
        precondition(!sessionID.isEmpty)
        connections[sessionID] = connection
    }

    func connection(
        for sessionID: String
    ) -> PersistentSocketLineConnection? {
        connections[sessionID]
    }

    @discardableResult
    func removeConnection(
        for sessionID: String
    ) -> PersistentSocketLineConnection? {
        connections.removeValue(forKey: sessionID)
    }

    func removeAllConnections() {
        connections.removeAll()
    }
}
