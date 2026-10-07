import CmuxLink

/// What a harness provides for one test case: the dialer's carriers, the
/// host's acceptor and the peer to dial.
public struct ConformanceEndpoints: Sendable {
    public var carriers: [any LinkCarrier]
    public var acceptor: any LinkAcceptor
    public var peer: LinkPeer

    public init(carriers: [any LinkCarrier], acceptor: any LinkAcceptor, peer: LinkPeer = LinkPeer(hostID: "conformance-host")) {
        self.carriers = carriers
        self.acceptor = acceptor
        self.peer = peer
    }
}
