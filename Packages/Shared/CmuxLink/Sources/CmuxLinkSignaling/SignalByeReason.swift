/// Why a peer ended a signaling session (`signal.bye`).
public enum SignalByeReason: String, Sendable, Hashable, CaseIterable {
    case closed
    case failed
    case superseded
    /// The peer refused our identity (unpaired, revoked or a bad signature).
    case revoked
}
