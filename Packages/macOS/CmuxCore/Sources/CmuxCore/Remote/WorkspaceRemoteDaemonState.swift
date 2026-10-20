/// Lifecycle state of the cmuxd-remote daemon backing a remote workspace.
///
/// Raw values are wire/persisted strings (status payloads): do not rename
/// cases.
public enum WorkspaceRemoteDaemonState: String, Sendable {
    /// No daemon is reachable.
    case unavailable
    /// The daemon binary is being uploaded/started on the remote host.
    case bootstrapping
    /// The daemon answered its hello and is serving RPCs.
    case ready
    /// The daemon failed to start or stopped unexpectedly.
    case error
}
