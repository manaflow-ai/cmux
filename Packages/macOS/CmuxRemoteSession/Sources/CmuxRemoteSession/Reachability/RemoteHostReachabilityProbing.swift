public import Foundation

/// Reachability-probe seam for the session coordinator's reconnect policy,
/// so tests can script outcomes instead of resolving and dialing real
/// endpoints. Production is ``RemoteHostReachabilityProbe``.
public protocol RemoteHostReachabilityProbing: Sendable {
    /// Probe the SSH endpoint for `destination`. The completion runs on an
    /// arbitrary queue; callers hop back to their own queue.
    func probe(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        completion: @escaping @Sendable (RemoteHostProbeOutcome) -> Void
    )
}
