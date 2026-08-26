/// Coalesces and guards persistent-PTY readiness without re-entering its broker.
public protocol ControlRemotePTYLifecycleCommitLease: Sendable {
    /// Claims the single worker-to-main readiness delivery for this lifecycle.
    ///
    /// - Returns: Whether the caller acquired the delivery, must wait for an
    ///   in-flight delivery, can reuse a completed acknowledgement, or is stale.
    func beginReadinessDelivery() -> ControlRemotePTYReadinessDeliveryAdmission

    /// Completes an acquired readiness delivery.
    ///
    /// A failed delivery becomes available for a later retry. A successful
    /// delivery remains completed until the broker invalidates the lifecycle.
    ///
    /// - Parameter succeeded: Whether the main-actor mutation was accepted.
    func finishReadinessDelivery(succeeded: Bool)

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
