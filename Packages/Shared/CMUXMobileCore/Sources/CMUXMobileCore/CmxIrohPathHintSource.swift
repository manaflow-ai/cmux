/// The provider that discovered an Iroh path hint.
///
/// Provenance affects privacy and routing policy, never peer authentication.
public enum CmxIrohPathHintSource: String, Codable, Sendable {
    /// Iroh's native discovery or relay configuration supplied the hint.
    case native
    /// Local-link discovery supplied the hint.
    case lan
    /// Tailscale supplied the hint.
    case tailscale
    /// A user-configured private-network or VPN provider supplied the hint.
    case customVPN = "custom_vpn"
}
