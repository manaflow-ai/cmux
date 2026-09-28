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

    /// Whether a link that resolved to `url` may open a file on this Mac.
    ///
    /// Only a click on content that came from this Mac opens a local file. A
    /// path in a remote or unplaced terminal names a file on another machine,
    /// so it never falls back to this Mac's filesystem. A remote machine can't
    /// ask this Mac to open a local file either, so apps and scripts on this
    /// Mac never launch without a click here.
    ///
    /// - Parameters:
    ///   - url: The link after path resolution.
    ///   - localContent: Whether the link came from a terminal known to run on
    ///     this Mac, or from a file this Mac's terminal wrote.
    ///   - remoteInitiated: Whether the remote machine asked for the open
    ///     without a click on this Mac.
    public func allowsLocalFile(_ url: URL, localContent: Bool, remoteInitiated: Bool) -> Bool {
        guard url.scheme?.lowercased() == "file" else { return true }
        return localContent && !remoteInitiated
    }
}
