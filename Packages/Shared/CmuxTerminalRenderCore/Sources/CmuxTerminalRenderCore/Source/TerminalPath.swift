/// How a terminal's bytes reach the phone (transport plan): shown as a
/// badge; a relayed path never reads as direct.
public enum TerminalPath: String, Hashable, Sendable {
    /// Same network as the host.
    case lan
    /// A NAT-punched or user-entered direct path (WireGuard, Tailscale, LAN address).
    case direct
    /// Through the cloud tunnel into the team network ("via cloud region").
    case viaCloudRegion
    /// The per-host relay fallback (TURN or Durable Object).
    case relayed
}
