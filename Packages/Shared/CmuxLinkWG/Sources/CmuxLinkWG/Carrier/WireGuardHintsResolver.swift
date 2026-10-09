public import CmuxLink

/// Reads the host key from `LinkPeer.hints["wg.hostKey"]` (base64).
public struct WireGuardHintsResolver: WireGuardHostKeyResolver {
    public static let hostKeyHint = "wg.hostKey"

    public init() {}

    public func hostKey(for peer: LinkPeer) async -> WireGuardPublicKey? {
        peer.hints[Self.hostKeyHint].flatMap(WireGuardPublicKey.init(base64:))
    }

    /// Hints carrying `key`, to merge into a `LinkPeer`.
    public func hints(for key: WireGuardPublicKey) -> [String: String] {
        [Self.hostKeyHint: key.base64]
    }
}
