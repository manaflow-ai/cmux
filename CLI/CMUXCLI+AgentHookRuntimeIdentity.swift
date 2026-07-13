import Foundation

extension CMUXCLI {
    /// Resolves hook-store ownership from the connected cmux process without
    /// touching the UI thread. `system.capabilities` is a socket-worker pure
    /// probe; its one-second bound and environment fallback keep hooks safe for
    /// older or unavailable servers.
    func agentHookStoreEnvironment(
        environment: [String: String],
        client: SocketClient
    ) -> [String: String] {
        let capabilities = (try? client.sendV2(
            method: "system.capabilities",
            responseTimeout: 1
        )) ?? [:]
        guard let identity = AgentCmuxRuntimeIdentity.resolve(
            environment: environment,
            socketCapabilities: capabilities
        ) else {
            return environment
        }
        return identity.applying(to: environment)
    }
}
