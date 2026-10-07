public import CmuxLink

/// Maps a peer to its direct endpoints, best first: the hosts store's
/// direct addresses, Bonjour results joined with the paired key.
public protocol DirectEndpointResolver: Sendable {
    func endpoints(for peer: LinkPeer) async -> [DirectEndpoint]
}
