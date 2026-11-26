public import CmuxCore
public import Dispatch
internal import Foundation

/// Process-wide brokering of shared remote daemon proxy tunnels, keyed by
/// transport configuration: workspaces pointing at the same remote share one
/// tunnel, reference-counted by ``RemoteProxyLease``.
///
/// ``RemoteProxyBroker`` is the production conformer. One instance is
/// constructed at the app's composition layer and injected into every remote
/// session controller (the legacy `static let shared` singleton is gone).
///
/// RPC methods are synchronous by contract. Wrapper-end retirement claims its
/// generation synchronously, then enqueues the tunnel-local cleanup.
public protocol RemoteProxyBrokering: AnyObject, Sendable {
    /// Subscribes to the shared tunnel for `configuration`, starting it when
    /// no tunnel exists yet (or restarting it when `remotePath` changed).
    ///
    /// `onUpdate` fires synchronously with the current state
    /// (`.ready`/`.connecting`) before `acquire` returns, then again on every
    /// later change, on an arbitrary queue. The returned lease keeps the
    /// tunnel alive; releasing the last lease tears it down.
    func acquire(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUpdate: @escaping @Sendable (RemoteProxyBrokerUpdate) -> Void
    ) -> RemoteProxyLease

    /// Lists persistent PTY sessions through the ready tunnel for
    /// `configuration`; throws when no tunnel is ready.
    func listPTY(configuration: WorkspaceRemoteConfiguration) throws -> [[String: Any]]

    /// Closes a persistent PTY session through the ready tunnel before `deadline`.
    ///
    /// - Parameters:
    ///   - configuration: Remote transport whose ready tunnel owns the PTY.
    ///   - sessionID: Persistent PTY session to terminate.
    ///   - deadline: Monotonic deadline shared with the originating cleanup call.
    func closePTY(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        deadline: DispatchTime
    ) throws

    /// Returns the shared lifecycle for one logical PTY attach generation.
    func ptySessionLifecycle(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        lifecycleID: String
    ) throws -> RemotePTYSessionLifecycle

    /// Retires one logical PTY attach generation after CLI reconciliation.
    func acknowledgePTYLifecycle(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        lifecycleID: String
    ) throws

    /// Returns the current broker owner for a wrapper generation.
    func currentPTYLifecycleOwner(
        sessionID: String,
        lifecycleID: String
    ) -> RemotePTYLifecycleOwner?

    /// Returns the broker owner that a wrapper-end callback must match.
    ///
    /// Unlike ``currentPTYLifecycleOwner(sessionID:lifecycleID:)``, this lookup
    /// also resolves a stale or just-ended generation so its cleanup can be
    /// reconciled without treating it as current readiness authority.
    ///
    /// - Parameters:
    ///   - sessionID: The persistent PTY session identifier.
    ///   - lifecycleID: The wrapper lifecycle generation.
    /// - Returns: The owner that must still match at claim time, or `nil` when
    ///   the lifecycle is unknown.
    func ptyLifecycleOwnerForWrapperEnd(
        sessionID: String,
        lifecycleID: String
    ) -> RemotePTYLifecycleWrapperEndOwner?

    /// Claims and enqueues retirement of a wrapper-owned generation.
    ///
    /// - Parameters:
    ///   - sessionID: The persistent PTY session identifier.
    ///   - lifecycleID: The wrapper lifecycle generation.
    /// - Returns: The exact retired ownership, or `nil` when it is unknown.
    @discardableResult
    func claimPTYLifecycleAfterWrapperEnd(
        sessionID: String,
        lifecycleID: String
    ) -> RemotePTYLifecycleWrapperEndClaim?

    /// Conditionally claims and enqueues retirement of a wrapper generation.
    ///
    /// The production broker compares `expectedOwner` and removes the
    /// lifecycle in one queue-confined operation.
    ///
    /// - Parameters:
    ///   - sessionID: The persistent PTY session identifier.
    ///   - lifecycleID: The wrapper lifecycle generation.
    ///   - expectedOwner: The transport and attachment validated by the caller.
    /// - Returns: The exact retired ownership, or `nil` if ownership changed.
    @discardableResult
    func claimPTYLifecycleAfterWrapperEnd(
        sessionID: String,
        lifecycleID: String,
        expectedOwner: RemotePTYLifecycleWrapperEndOwner
    ) -> RemotePTYLifecycleWrapperEndClaim?

    /// Claims and enqueues retirement of a wrapper-owned generation.
    ///
    /// - Returns: Whether this was the current generation for its attachment.
    @discardableResult
    func acknowledgePTYLifecycleAfterWrapperEnd(sessionID: String, lifecycleID: String) -> Bool

    /// Resizes a PTY attachment through the ready tunnel.
    func resizePTY(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        cols: Int,
        rows: Int
    ) throws

    /// Detaches a PTY attachment through the ready tunnel.
    func detachPTY(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        attachmentID: String,
        attachmentToken: String
    ) throws

    /// Starts a loopback PTY bridge through the ready tunnel and returns its
    /// endpoint.
    func startPTYBridge(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        lifecycleID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) throws -> RemotePTYBridgeServer.Endpoint
}

extension RemoteProxyBrokering {
    /// Compatibility lookup for conformers without ended-generation state.
    ///
    /// - Parameters:
    ///   - sessionID: The persistent PTY session identifier.
    ///   - lifecycleID: The wrapper lifecycle generation.
    /// - Returns: The current owner adapted for wrapper-end validation, or
    ///   `nil` when the lifecycle is not current.
    public func ptyLifecycleOwnerForWrapperEnd(
        sessionID: String,
        lifecycleID: String
    ) -> RemotePTYLifecycleWrapperEndOwner? {
        currentPTYLifecycleOwner(
            sessionID: sessionID,
            lifecycleID: lifecycleID
        ).map {
            RemotePTYLifecycleWrapperEndOwner(
                transportKey: $0.transportKey,
                attachmentID: $0.attachmentID
            )
        }
    }

    /// Compatibility claim for test fakes that do not own production broker
    /// queue state. ``RemoteProxyBroker`` overrides this with one atomic claim.
    ///
    /// - Parameters:
    ///   - sessionID: The persistent PTY session identifier.
    ///   - lifecycleID: The wrapper lifecycle generation.
    /// - Returns: The exact retired ownership, or `nil` when it is unknown.
    @discardableResult
    public func claimPTYLifecycleAfterWrapperEnd(
        sessionID: String,
        lifecycleID: String
    ) -> RemotePTYLifecycleWrapperEndClaim? {
        guard let owner = currentPTYLifecycleOwner(
            sessionID: sessionID,
            lifecycleID: lifecycleID
        ) else {
            return nil
        }
        let wasCurrent = acknowledgePTYLifecycleAfterWrapperEnd(
            sessionID: sessionID,
            lifecycleID: lifecycleID
        )
        return RemotePTYLifecycleWrapperEndClaim(
            transportKey: owner.transportKey,
            attachmentID: owner.attachmentID,
            wasCurrent: wasCurrent
        )
    }
}
