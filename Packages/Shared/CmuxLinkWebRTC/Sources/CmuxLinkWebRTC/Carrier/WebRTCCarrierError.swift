/// Why a WebRTC connect failed.
public enum WebRTCCarrierError: Error, Sendable, Hashable {
    /// No pinned host identity key for the peer (pairing missing).
    case noHostKey
    /// Signaling, ICE, DTLS or authentication did not complete.
    case connectFailed(String)
}
