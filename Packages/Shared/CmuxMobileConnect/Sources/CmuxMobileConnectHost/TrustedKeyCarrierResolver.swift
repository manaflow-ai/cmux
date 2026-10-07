public import CmuxLink
public import CmuxMobileHost
public import CmuxPairing

/// B5's `CarrierKeyResolver` over B6's verified trust store: a Noise key
/// (B4) maps to the install whose `direct` cert names it, a WireGuard key
/// (B3) to the one whose `wg` cert does. P-256 keys come with an install
/// (B2), so they never need a lookup.
public struct TrustedKeyCarrierResolver: CarrierKeyResolver {
    private let lookup: any TrustedKeyLookup
    private let hostID: String

    public init(lookup: any TrustedKeyLookup, hostID: String) {
        self.lookup = lookup
        self.hostID = hostID
    }

    public func install(for identity: LinkPeerIdentity) async -> String? {
        guard identity.keyKind == .x25519 else { return nil }
        let purpose: LinkPurpose = identity.carrier == .webrtcWireGuard ? .wg : .direct
        return await lookup.trustedInstall(linkKey: identity.publicKey, purpose: purpose, onHost: hostID)
    }
}
