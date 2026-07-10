internal import CMUXMobileCore

extension MobileCoreRPCSession {
    /// Live transport diagnostics (path kind, RTT, relay, bytes) for the session's
    /// active connection, or nil when no transport is connected.
    func connectionDiagnostics() async -> CmxConnectionDiagnostics? {
        guard let transport else { return nil }
        return await transport.connectionDiagnostics()
    }
}
