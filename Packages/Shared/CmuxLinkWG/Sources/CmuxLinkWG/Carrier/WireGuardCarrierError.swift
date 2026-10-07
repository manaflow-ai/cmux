/// Errors of the V2 carrier.
public enum WireGuardCarrierError: Error, Sendable, Hashable {
    /// No host key for the peer (no `wg.hostKey` hint, resolver had none).
    case missingHostKey(hostID: String)
    case handshakeTimeout
    /// The transport is closed or closing.
    case closed
    /// Media tracks would leave WireGuard; V2 carries media as channel data.
    case mediaUnsupported
}
