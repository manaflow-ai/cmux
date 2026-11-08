public import Dispatch
internal import Foundation

/// The proxy-tunnel operations ``RemoteProxyBroker`` drives on each
/// per-transport tunnel it owns: lifecycle plus the synchronous persistent-PTY
/// RPCs forwarded from session controllers.
///
/// `RemoteDaemonProxyTunnel` is the production conformer; the seam exists so
/// the broker depends on a protocol rather than the concrete tunnel
/// (constructor-injection convention) and so broker tests can drive the
/// restart/teardown state machine with fakes instead of spawning real SSH
/// transports.
///
/// All methods are synchronous by contract: callers run on serial utility
/// queues (the broker queue, the session-controller queue) and need blocking
/// results mid-flow, matching the legacy `WorkspaceRemoteDaemonProxyTunnel`
/// call shape.
public protocol RemoteProxyTunneling: AnyObject {
    /// Starts the tunnel's RPC transport and loopback listener; throws when
    /// either fails (the tunnel is then unusable).
    func start() throws

    /// Stops the listener, sessions, PTY bridges, and RPC transport.
    func stop()

    /// Stops one replaceable runtime while preserving its logical PTY lifecycle.
    func stopPreservingPTYLifecycle() -> RemotePTYLifecycleSnapshot

    /// Restores logical PTY lifecycle before a replacement tunnel starts.
    func restorePTYLifecycle(_ snapshot: RemotePTYLifecycleSnapshot)

    /// Lists the daemon's persistent PTY sessions (raw JSON objects, wire
    /// shape pinned).
    func listPTY() throws -> [[String: Any]]

    /// Closes a persistent PTY session on the daemon before `deadline`.
    ///
    /// - Parameters:
    ///   - sessionID: Persistent PTY session to terminate.
    ///   - deadline: Monotonic deadline shared with the originating cleanup call.
    func closePTY(sessionID: String, deadline: DispatchTime) throws

    /// Returns the shared lifecycle for one logical PTY attach generation.
    func ptySessionLifecycle(sessionID: String, lifecycleID: String) -> RemotePTYSessionLifecycle

    /// Retires one logical PTY attach generation after CLI reconciliation.
    func acknowledgePTYLifecycle(sessionID: String, lifecycleID: String)

    /// Retires the generation only when this tunnel owns it.
    func acknowledgePTYLifecycleIfKnown(sessionID: String, lifecycleID: String) -> Bool

    /// Resizes a PTY attachment.
    func resizePTY(sessionID: String, attachmentID: String, attachmentToken: String, cols: Int, rows: Int) throws

    /// Detaches a PTY attachment, surfacing daemon-side errors.
    func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) throws

    /// Starts a single-use loopback PTY bridge server for a terminal attach
    /// and returns its endpoint.
    func startPTYBridge(
        sessionID: String,
        lifecycleID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool,
        onLifecycleEnded: @escaping @Sendable () -> Void
    ) throws -> RemotePTYBridgeServer.Endpoint
}
