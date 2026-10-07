public import CmuxLink

/// Gives the dialer the host's WireGuard key, pinned at pairing (B6).
public protocol WireGuardHostKeyResolver: Sendable {
    func hostKey(for peer: LinkPeer) async -> WireGuardPublicKey?
}
