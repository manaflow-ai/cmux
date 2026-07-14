import Foundation

extension CMUXCLI {
    /// Adds the connected app's runtime identity to direct store queries. A CLI
    /// launched from a normal shell has no inherited `CMUX_RUNTIME_ID`, while a
    /// CLI launched inside a different cmux can inherit the wrong one. An
    /// explicit `--socket` names the authority, so connected evidence wins.
    func agentSessionQueryEnvironment(
        environment: [String: String],
        socketCapabilities: [String: Any]
    ) -> [String: String] {
        guard let identity = AgentCmuxRuntimeIdentity.resolve(
            environment: environment,
            socketCapabilities: socketCapabilities
        ) else {
            return environment
        }
        return identity.applying(to: environment)
    }

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
        return agentSessionQueryEnvironment(
            environment: environment,
            socketCapabilities: capabilities
        )
    }
}
