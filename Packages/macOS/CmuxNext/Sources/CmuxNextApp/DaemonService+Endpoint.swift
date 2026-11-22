import CmuxNextDaemon

/// The daemon's capabilities and its socket, for callers that open their own connection.
extension DaemonService {
    func supports(_ capability: String) -> Bool {
        store.supports(capability)
    }

    /// The socket for dedicated terminal attachments (re-read on reconnect).
    func endpoint() async throws -> DaemonEndpoint {
        if policyBlock.isBlocked { throw DaemonError.endpointBlocked("turned off by your organization") }
        if connection == nil, startup == .connecting, isStarting { await firstConnection() }
        guard let connection, let endpoint = await connection.endpoint else { throw DaemonError.notConnected }
        return endpoint
    }
}
