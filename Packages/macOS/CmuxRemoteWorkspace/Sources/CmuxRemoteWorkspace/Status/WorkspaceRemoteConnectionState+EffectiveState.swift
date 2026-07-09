public import CmuxCore

extension WorkspaceRemoteConnectionState {
    /// Resolves the *effective* connection state a remote workspace should
    /// display, given the raw state a session reports (`self`).
    ///
    /// A proxy-only failure (the local daemon proxy / SSH relay broke, but the
    /// remote host and its SSH terminal are still alive) must not be surfaced as
    /// a hard disconnect while the SSH terminal keeps running. So when the
    /// workspace is preserving a proxy-only failure, a reported `.error` whose
    /// detail indicates a proxy-only fault, and the in-flight
    /// `.connecting`/`.reconnecting` retries that follow it, are all collapsed
    /// back to `.connected`. Every other reported state passes through unchanged.
    ///
    /// The live "preserves proxy failure" and "has proxy-only sidebar error"
    /// predicates stay on the workspace (they read mutable workspace state); this
    /// pure fold only consumes the resulting booleans, matching the legacy inline
    /// computation in `Workspace.applyRemoteConnectionStateUpdate(_:detail:target:)`
    /// byte for byte.
    ///
    /// - Parameters:
    ///   - isProxyOnlyError: Whether the reported detail indicates a proxy-only
    ///     fault (see ``Swift/String/indicatesProxyOnlyRemoteError``).
    ///   - preservesProxyFailureWhileSSHTerminalIsAlive: Whether the workspace
    ///     is currently keeping a proxy-only failure from tearing down a live
    ///     SSH terminal.
    ///   - hasProxyOnlySidebarError: Whether the workspace's sidebar currently
    ///     shows a proxy-only error.
    /// - Returns: The effective state, with proxy-only faults and their retries
    ///   collapsed to `.connected` and all other states passed through.
    public func effectiveRemoteConnectionState(
        isProxyOnlyError: Bool,
        preservesProxyFailureWhileSSHTerminalIsAlive: Bool,
        hasProxyOnlySidebarError: Bool
    ) -> WorkspaceRemoteConnectionState {
        let preserveConnectedStateForRetry =
            (self == .connecting || self == .reconnecting)
            && preservesProxyFailureWhileSSHTerminalIsAlive
            && hasProxyOnlySidebarError
        if self == .error
            && isProxyOnlyError
            && preservesProxyFailureWhileSSHTerminalIsAlive {
            return .connected
        } else if preserveConnectedStateForRetry {
            return .connected
        } else {
            return self
        }
    }
}
