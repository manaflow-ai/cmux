public import Foundation

/// Chooses where a link from a remote terminal opens.
public struct RemoteLinkOpenPolicy: Sendable {
    private let hosts: PrivateNetworkHostPolicy

    /// Creates the policy.
    public init(hosts: PrivateNetworkHostPolicy = PrivateNetworkHostPolicy()) {
        self.hosts = hosts
    }

    /// The destinations for `url`.
    ///
    /// - Parameters:
    ///   - url: The link as the remote terminal wrote it.
    ///   - machineRoute: The same link rewritten to the remote machine's own
    ///     address, when the link names the remote machine's loopback.
    ///   - remoteInitiated: Whether the remote machine asked for the open
    ///     without a click on this Mac.
    public func destinations(for url: URL, machineRoute: URL?, remoteInitiated: Bool) -> RemoteLinkDestinations {
        RemoteLinkDestinations(browserURL: machineRoute ?? url, externalURL: machineRoute ?? url)
    }
}
