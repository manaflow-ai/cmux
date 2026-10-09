/// Which interfaces and candidates a peer connection uses.
public enum WebRTCNetworkMode: Sendable, Hashable {
    /// Every interface except loopback; candidates as gathered.
    case standard
    /// Loopback only, host candidates only (in-process tests).
    case loopbackOnly
}
