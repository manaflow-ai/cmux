public import CmuxLinkDirect
public import CmuxLinkWebRTC
public import CmuxLinkWG

/// The Mac's identity for every acceptor: its host id and account, the
/// X25519 key its `direct` cert names (B4), its install key for WebRTC
/// fingerprints (B2) and its `wg` key (B3).
public struct MobileHostCredentials: Sendable {
    public var hostID: String
    public var accountUserID: String
    public var direct: DirectIdentity
    public var webrtc: (any WebRTCIdentity)?
    public var wireGuard: WireGuardPrivateKey?

    public init(hostID: String, accountUserID: String, direct: DirectIdentity, webrtc: (any WebRTCIdentity)? = nil,
                wireGuard: WireGuardPrivateKey? = nil) {
        self.hostID = hostID
        self.accountUserID = accountUserID
        self.direct = direct
        self.webrtc = webrtc
        self.wireGuard = wireGuard
    }
}
