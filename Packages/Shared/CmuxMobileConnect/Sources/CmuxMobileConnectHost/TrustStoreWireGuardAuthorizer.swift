public import CmuxLinkWG
public import CmuxPairing

/// B3's host-side check over the trust store: a WireGuard key is allowed
/// when a verified `wg` cert of this account names it; its install names the
/// overlay address.
public struct TrustStoreWireGuardAuthorizer: WireGuardAuthorizer {
    private let lookup: any TrustedKeyLookup

    public init(lookup: any TrustedKeyLookup) {
        self.lookup = lookup
    }

    public func authorize(peer: WireGuardPublicKey) async -> WireGuardAuthorizedPeer? {
        guard let install = await lookup.trustedInstall(linkKey: peer.rawRepresentation, purpose: .wg, onHost: nil) else {
            return nil
        }
        return WireGuardAuthorizedPeer(installID: install)
    }
}
