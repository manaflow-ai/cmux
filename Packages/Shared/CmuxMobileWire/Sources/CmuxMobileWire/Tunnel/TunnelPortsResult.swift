/// `tunnel.ports` result: what this device may open with `tcp.forward` now.
public struct TunnelPortsResult: Hashable, Sendable, Codable {
    public var ports: [TunnelPort]

    public init(ports: [TunnelPort]) {
        self.ports = ports
    }
}
