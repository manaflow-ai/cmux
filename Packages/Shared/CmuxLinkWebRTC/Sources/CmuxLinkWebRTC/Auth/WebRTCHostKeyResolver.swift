public import CmuxLink

/// The host identity key a dialer expects (the pairing record). No key, no
/// connect.
public protocol WebRTCHostKeyResolver: Sendable {
    func hostKey(for peer: LinkPeer) async -> WebRTCPublicKey?
}
