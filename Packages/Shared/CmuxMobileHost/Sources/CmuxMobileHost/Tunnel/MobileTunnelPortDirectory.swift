public import CmuxMobileWire

/// The ports this Mac lets a device forward now (the app implements it over
/// its workspaces; `DetectedTunnelPorts` is the standard implementation).
/// Evaluated on every `channel.open` and `tunnel.ports` read; never cached
/// from the phone.
public protocol MobileTunnelPortDirectory: Sendable {
    func ports(for principal: MobileDevicePrincipal) async -> [TunnelPort]
}
