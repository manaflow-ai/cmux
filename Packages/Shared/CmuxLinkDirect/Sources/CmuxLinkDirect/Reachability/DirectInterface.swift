/// One network interface in a path snapshot.
public struct DirectInterface: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case wifi
        case wired
        case cellular
        case loopback
        /// Tunnels (`utun*`, `ipsec*`): Tailscale, WireGuard and other VPNs.
        case other
    }

    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// A VPN tunnel interface, which is how a Tailscale or WireGuard route
    /// appears to apps on iOS and macOS.
    public var isTunnel: Bool {
        kind == .other && (name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("tun") || name.hasPrefix("wg"))
    }

    public var isLocalNetwork: Bool { kind == .wifi || kind == .wired }
}
