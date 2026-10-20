public import CmuxCore
public import Foundation

/// The coordinator's one-way publish seam back to the owning workspace model.
///
/// This is the narrow surface the legacy `WorkspaceRemoteSessionController`
/// used on `Workspace` (six `applyRemote*` callbacks). The app-side conformer
/// owns the main-queue hop, the weak workspace reference, and the
/// controller-ID guard that drops stale publishes from a replaced session
/// coordinator; the coordinator itself never sees the workspace model.
///
/// Every method may be called from the coordinator's private serial queue and
/// must be safe to invoke from any thread.
public protocol RemoteSessionHosting: Sendable {
    /// Publish a connection-state transition with an optional detail string.
    func publishConnectionState(_ state: WorkspaceRemoteConnectionState, detail: String?)
    /// Publish a daemon status snapshot (bootstrapping/ready/error/...).
    func publishDaemonStatus(_ status: WorkspaceRemoteDaemonStatus)
    /// Publish the shared local proxy endpoint, or `nil` when it goes away.
    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?)
    /// Publish the detected remote listening ports, per tracked panel and as
    /// a merged sorted list.
    func publishPortsSnapshot(detectedByPanel: [UUID: [Int]], detected: [Int])
    /// Publish daemon heartbeat activity (a monotonically increasing count
    /// and the time it was recorded).
    func publishHeartbeat(count: Int, lastSeenAt: Date?)
    /// Publish the remote TTY name resolved for the workspace's bootstrap
    /// terminal.
    func publishBootstrapRemoteTTY(_ ttyName: String)
}
