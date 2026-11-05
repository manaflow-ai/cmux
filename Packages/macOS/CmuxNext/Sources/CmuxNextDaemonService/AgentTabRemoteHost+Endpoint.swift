public import CmuxNextDaemon

extension AgentTabRemoteHost {
    /// A reconnect replaces a Cloud link's ticket and the daemon's endpoint provider. Resolve
    /// that provider for each connection attempt so a retry never retains the superseded ticket.
    @MainActor public static func endpoint(on daemon: DaemonService) -> AgentSessionAttachClient.EndpointProvider {
        { [weak daemon] in
            guard let provider = await daemon?.remoteEndpoint else { throw DaemonError.notConnected }
            return try await provider()
        }
    }
}
