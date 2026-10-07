public import CmuxLink

/// Reads the pinned host key from `LinkPeer.hints["webrtc.hostKey"]`
/// (base64 X9.63), the shape B4 uses for `direct.hostKey`.
public struct WebRTCHintsResolver: WebRTCHostKeyResolver {
    public static let hostKeyHint = "webrtc.hostKey"
    /// Optional signal target (the host's install id); defaults to `hostID`.
    public static let signalTargetHint = "webrtc.to"

    public init() {}

    public func hostKey(for peer: LinkPeer) async -> WebRTCPublicKey? {
        peer.hints[Self.hostKeyHint].flatMap(WebRTCPublicKey.init(base64:))
    }

    /// The hints that pin `key` for `hostID`.
    public func hints(hostKey key: WebRTCPublicKey, signalTarget: String? = nil) -> [String: String] {
        var hints = [Self.hostKeyHint: key.base64]
        if let signalTarget { hints[Self.signalTargetHint] = signalTarget }
        return hints
    }
}
