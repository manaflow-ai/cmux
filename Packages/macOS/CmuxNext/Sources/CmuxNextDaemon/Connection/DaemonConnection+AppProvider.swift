extension DaemonConnection {
    /// Registers app families without sending an unsupported `agent_cli` name to a legacy owner.
    ///
    /// Capability admission runs on the captured ready transport, after any
    /// handoff wait. Only a missing capability omits the new family; conflicts,
    /// transport failures and other owner refusals propagate to the caller.
    /// - Parameter families: The families implemented by this verified app connection.
    /// - Returns: The daemon's registration result.
    /// - Throws: Cancellation, registration refusal or transport failure.
    public func registerAppProvider(families: [String]) async throws -> JSONValue {
        try Task.checkCancellation()
        if families.contains("agent_cli") {
            do {
                return try await request(AgentCLIProviderRegisterRequest(families: families))
            } catch DaemonError.missingCapabilities(let missing) where missing == ["agent-cli-app-provider-v1"] {
                // No registration was sent; keep the older families available.
            }
        }
        try Task.checkCancellation()
        return try await request(AppsProviderRegisterRequest(families: families.filter { $0 != "agent_cli" }))
    }
}
