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
