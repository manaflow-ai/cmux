import CmuxLink

/// A carrier on a `LoopbackNetwork`. With network conditions set it is the
/// lossy, latency, jitter and roam simulator.
public struct LoopbackCarrier: LinkCarrier {
    public let network: LoopbackNetwork
    public let kind: CarrierKind
    public let defaultPath: PathKind
    public let candidatePaths: [PathKind]
    public let capabilities: TransportCapabilities

    public func connect(to peer: LinkPeer) async throws -> any LinkTransport {
        try await network.connect(self)
    }
}
