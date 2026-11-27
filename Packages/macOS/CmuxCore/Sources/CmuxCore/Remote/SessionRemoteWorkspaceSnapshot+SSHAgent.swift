import CmuxFoundation

extension SessionRemoteWorkspaceSnapshot {
    /// Selects a live saved agent, falling back to the current launch environment.
    ///
    /// An explicitly disabled saved agent never falls back to an inherited one.
    /// The caller supplies liveness checks so this persistence policy performs no I/O.
    ///
    /// - Parameters:
    ///   - environment: The environment of the process restoring the workspace.
    ///   - isLiveAgent: Whether a normalized socket path accepts trusted agent connections.
    /// - Returns: The first live socket in saved-then-inherited order, or `nil`.
    public func restoredAgentSocketPath(
        environment: [String: String],
        isLiveAgent: (String) -> Bool
    ) -> String? {
        let resolver = SSHAgentSocketResolver(environment: [:])
        if agentSocketPathOverrideIsSet == true, resolver.normalizedAgentSocketPath(agentSocketPath) == nil {
            return nil
        }
        return [agentSocketPath, environment["SSH_AUTH_SOCK"]]
            .lazy
            .compactMap { resolver.normalizedAgentSocketPath($0) }
            .first(where: isLiveAgent)
    }
}
