public import Foundation

/// Chooses where a link from a remote terminal opens.
///
/// A remote machine can ask this Mac to open a URL without a click. Such an
/// open must not reach this Mac's loopback or local network, so it never hands
/// a non-public URL to the default browser.
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
        guard let machineRoute else {
            let opens = !remoteInitiated || !hosts.isNonPublic(host: url.host ?? "")
            return RemoteLinkDestinations(browserURL: opens ? url : nil, externalURL: opens ? url : nil)
        }
        // An SSH machine's route is this Mac's loopback proxy, which only the
        // cmux browser resolves to the remote machine. In the default browser
        // it would reach this Mac's own services.
        guard hosts.isLoopback(host: machineRoute.host ?? "") else {
            return RemoteLinkDestinations(browserURL: machineRoute, externalURL: machineRoute)
        }
        return RemoteLinkDestinations(browserURL: machineRoute, externalURL: remoteInitiated ? nil : url)
    }
}
