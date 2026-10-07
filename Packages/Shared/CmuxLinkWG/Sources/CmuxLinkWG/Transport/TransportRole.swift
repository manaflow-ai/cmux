import CmuxLink

/// Which end of the session a transport is, and how it replaces a dead
/// underlay: the dialer opens a new one, the host waits for it.
enum TransportRole: Sendable {
    case dialer(underlays: any DatagramUnderlayDialer, peer: LinkPeer)
    case host
}
