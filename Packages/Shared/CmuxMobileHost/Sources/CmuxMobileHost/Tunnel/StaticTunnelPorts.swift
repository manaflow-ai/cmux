public import CmuxMobileWire

/// A fixed port list (tests, DEV).
public struct StaticTunnelPorts: MobileTunnelPortDirectory {
    public var ports: [TunnelPort]

    public init(_ ports: [TunnelPort]) {
        self.ports = ports
    }

    public func ports(for principal: MobileDevicePrincipal) async -> [TunnelPort] {
        ports
    }
}
