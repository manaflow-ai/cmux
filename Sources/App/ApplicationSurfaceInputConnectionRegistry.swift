import CmuxControlSocket

@MainActor
final class ApplicationSurfaceInputConnectionRegistry {
    private let transport: SocketTransport
    private var connections: [String: PersistentSocketLineConnection] = [:]

    init(transport: SocketTransport) {
        self.transport = transport
    }

    func connection(for sessionID: String) -> PersistentSocketLineConnection {
        if let connection = connections[sessionID] {
            return connection
        }
        let connection = PersistentSocketLineConnection(transport: transport)
        connections[sessionID] = connection
        return connection
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
