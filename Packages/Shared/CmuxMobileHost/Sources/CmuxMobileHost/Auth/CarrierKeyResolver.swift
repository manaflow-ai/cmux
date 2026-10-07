public import CmuxLink

/// Maps a key a carrier authenticated without naming an install (B4's Noise
/// static key) to the install that owns it in the trust store (B6's
/// `TrustedKeyLookup`). Nil means no install of this account owns the key.
public protocol CarrierKeyResolver: Sendable {
    func install(for identity: LinkPeerIdentity) async -> String?
}
