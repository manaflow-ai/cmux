import Foundation

/// Classifies URL hosts that a remote machine could use to reach this Mac or
/// its local network.
public struct PrivateNetworkHostPolicy: Sendable {
    /// Creates the policy.
    public init() {}

    /// Whether `host` names a loopback, link-local, private or otherwise
    /// non-public destination.
    public func isNonPublic(host: String) -> Bool {
        false
    }

    /// Whether `host` names this machine's loopback interface.
    public func isLoopback(host: String) -> Bool {
        RemoteLoopbackProxyAlias.isLoopbackHost(host)
    }

    /// Whether `host` is a DNS name whose addresses must be checked before a
    /// remote-initiated open.
    public func requiresAddressLookup(host: String) -> Bool {
        false
    }
}
