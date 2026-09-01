/// The mode captured for one physical dial in the privacy-safe diagnostic ring.
public enum DiagnosticTransportMode: Int, Codable, CaseIterable, Hashable, Sendable {
    /// Normal automatic route selection.
    case automatic = 0
    /// A local-network-only policy.
    case lan = 1
    /// A Tailscale-only policy.
    case tailscale = 2
    /// An Iroh-only policy.
    case iroh = 3
    /// A configured direct-address policy.
    case direct = 4

    /// Converts a user-facing transport mode to its stable diagnostic value.
    ///
    /// - Parameter mode: The configured transport mode.
    public init(_ mode: CmxTransportMode) {
        switch mode {
        case .automatic: self = .automatic
        case .lan: self = .lan
        case .tailscale: self = .tailscale
        case .iroh: self = .iroh
        case .direct: self = .direct
        }
    }
}
