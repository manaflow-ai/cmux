/// Why a connected link is degraded. The link still carries traffic.
public enum DegradedReason: Sendable, Hashable {
    /// Smoothed RTT above `LinkConfiguration.degradedRTT`.
    case highLatency
    /// The carrier reports packet loss above its threshold.
    case packetLoss
    /// The carrier's send buffer stays full.
    case congested
    /// A carrier-specific reason.
    case carrier(String)
}
