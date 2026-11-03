public import NetworkExtension

extension CloudTunnelConfiguration {
    /// The packet tunnel's network settings: this Mac's addresses, only the Cloud routes (never a
    /// default route, no DNS change), the MTU, and the gateway as the tunnel's remote address.
    public func networkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: endpointHost)
        settings.mtu = NSNumber(value: mtu)
        let v4 = addresses.filter { $0.family == .ipv4 }
        let v4Routes = routes.filter { $0.family == .ipv4 && !$0.isDefaultRoute }
        if !v4.isEmpty {
            let ipv4 = NEIPv4Settings(addresses: v4.map(\.address), subnetMasks: v4.map { $0.ipv4Mask ?? "255.255.255.255" })
            ipv4.includedRoutes = v4Routes.map { NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.ipv4Mask ?? "255.255.255.255") }
            settings.ipv4Settings = ipv4
        }
        let v6 = addresses.filter { $0.family == .ipv6 }
        let v6Routes = routes.filter { $0.family == .ipv6 && !$0.isDefaultRoute }
        if !v6.isEmpty {
            let ipv6 = NEIPv6Settings(addresses: v6.map(\.address), networkPrefixLengths: v6.map { NSNumber(value: $0.prefix) })
            ipv6.includedRoutes = v6Routes.map { NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefix)) }
            settings.ipv6Settings = ipv6
        }
        return settings
    }
}
