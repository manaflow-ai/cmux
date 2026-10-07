public import CmuxMobileHost
public import CmuxMobileWire

/// A tunnel port directory without the ports this Mac's own services listen
/// on (the daemon and its terminal hosts, this app's link listener),
/// computed per request: an unadvertised port is refused, so a phone can
/// never forward to them (c14-web.md 3.2).
public struct FilteredTunnelPorts: MobileTunnelPortDirectory {
    private let base: any MobileTunnelPortDirectory
    private let denied: @Sendable () async -> Set<UInt16>

    public init(base: any MobileTunnelPortDirectory, denied: @escaping @Sendable () async -> Set<UInt16>) {
        self.base = base
        self.denied = denied
    }

    public func ports(for principal: MobileDevicePrincipal) async -> [TunnelPort] {
        let ports = await base.ports(for: principal)
        let denied = await denied()
        return ports.filter { !denied.contains($0.port) }
    }
}
