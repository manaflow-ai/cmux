/// Whether a direct route to an endpoint can work on the current path.
public enum DirectRouteStatus: Sendable, Hashable {
    case available
    case unavailable(Blocker)

    public enum Blocker: String, Sendable, Hashable {
        /// No usable network at all.
        case offline
        /// The address needs a VPN (Tailscale, WireGuard) and no tunnel is up.
        case noTunnel
        /// The address needs Wi-Fi or wired LAN (or a tunnel) and none is up.
        case noLocalNetwork
    }

    public var isAvailable: Bool { self == .available }
}
