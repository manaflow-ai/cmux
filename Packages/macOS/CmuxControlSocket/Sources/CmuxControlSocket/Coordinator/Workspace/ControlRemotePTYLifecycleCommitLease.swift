/// Guards a persistent-PTY readiness commit without re-entering its broker.
public protocol ControlRemotePTYLifecycleCommitLease: Sendable {
    /// Runs `operation` only while the authenticated PTY generation is current.
    ///
    /// - Parameter operation: The short main-actor model mutation to commit,
    ///   returning whether it applied.
    /// - Returns: Whether the current generation applied the mutation.
    @MainActor
    func commitIfCurrent(
        _ operation: @MainActor @Sendable () -> Bool
    ) -> Bool
}
