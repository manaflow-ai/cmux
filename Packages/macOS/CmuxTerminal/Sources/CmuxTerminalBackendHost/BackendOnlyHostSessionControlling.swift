internal import CmuxTerminalBackend

/// Connection lifecycle seam used by the host model and its process-free tests.
protocol BackendOnlyHostSessionControlling: Sendable {
    func connect() async throws -> BackendOnlyHostConnection

    func projectionRPC(
        for connection: BackendOnlyHostConnection
    ) async throws -> any BackendOnlyProjectionDriverRPC

    func events(
        for connection: BackendOnlyHostConnection
    ) async -> AsyncStream<BackendCanonicalSessionEvent>

    func currentSnapshot(
        for connection: BackendOnlyHostConnection
    ) async -> TopologySnapshot?

    func invalidate(_ connection: BackendOnlyHostConnection) async
}
