public import CmuxNextDaemon
public import Foundation

/// `MobileCompatBackend` over a dedicated daemon connection owned by the
/// mobile host, so phone traffic never queues behind the Mac's own tree
/// mirror or runs on the main actor.
public final class DaemonCompatBackend: MobileCompatBackend {
    private let connection: DaemonConnection
    private let changes = TreeChangeBroadcaster()

    /// Connects with tree deltas enabled and starts forwarding tree events.
    public static func connect(endpointProvider: @escaping DaemonConnection.EndpointProvider) async throws
        -> DaemonCompatBackend {
        let connection = DaemonConnection(
            configuration: DaemonConnection.Configuration(clientName: "cmux-next-mobile-compat"),
            endpointProvider: endpointProvider)
        try await connection.start()
        let backend = DaemonCompatBackend(connection: connection)
        backend.forwardEvents()
        return backend
    }

    private init(connection: DaemonConnection) {
        self.connection = connection
    }

    public func close() async {
        await connection.close()
        changes.finish()
    }

    private func forwardEvents() {
        let events = connection.events
        let changes = changes
        Task.detached {
            do {
                for try await _ in events { changes.signal() }
            } catch {}
            changes.finish()
        }
    }

    public func tree() async throws -> DaemonTree { try await connection.snapshot().tree }
    public func treeChanges() -> AsyncStream<Void> { changes.subscribe() }

    public func createWorkspace(name: String?) async throws -> WorkspaceKey {
        try await connection.createWorkspace(name: name).key
    }

    public func renameWorkspace(_ key: WorkspaceKey, to name: String) async throws {
        _ = try await connection.renameWorkspace(key, to: name)
    }

    public func closeWorkspace(_ key: WorkspaceKey) async throws {
        _ = try await connection.closeWorkspace(key)
    }

    public func createTerminal(in key: WorkspaceKey, cwd: String?) async throws -> TerminalID? {
        try await connection.createTerminal(in: key, cwd: cwd).terminalID
    }

    public func send(_ surface: SurfaceID, bytes: Data, paste: Bool) async throws {
        try await connection.send(surface, bytes: bytes, paste: paste)
    }

    public func renameTab(_ surface: SurfaceID, to name: String) async throws {
        try await connection.renameTab(surface, to: name)
    }

    public func closeTerminal(_ terminal: TerminalID) async throws {
        try await connection.closeTerminal(terminal)
    }

    public func attach(_ tab: TabSnapshot, generation: DaemonGeneration?, size: CellSize) async throws
        -> any MobileCompatTerminalChannel {
        guard let endpoint = await connection.endpoint else { throw DaemonError.notConnected }
        return try await TerminalAttachment.attach(
            endpoint: endpoint, target: .init(tab: tab, generation: generation), size: size,
            claimGeometry: false, clientName: "cmux-next-mobile-compat")
    }
}
