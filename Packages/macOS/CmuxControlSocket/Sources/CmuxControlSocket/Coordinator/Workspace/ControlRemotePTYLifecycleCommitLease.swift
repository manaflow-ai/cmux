/// Guards a persistent-PTY readiness commit without re-entering its broker.
public protocol ControlRemotePTYLifecycleCommitLease: Sendable {
    /// Runs `operation` only while the authenticated PTY generation is current.
    ///
    /// - Parameter operation: The short main-actor model mutation to commit.
    /// - Returns: The mutation result, or `nil` when the generation was retired.
    @MainActor
    func commitIfCurrent(
        _ operation: @MainActor () -> ControlWorkspaceRemoteTerminalSessionConnectedResolution
    ) -> ControlWorkspaceRemoteTerminalSessionConnectedResolution?
}
