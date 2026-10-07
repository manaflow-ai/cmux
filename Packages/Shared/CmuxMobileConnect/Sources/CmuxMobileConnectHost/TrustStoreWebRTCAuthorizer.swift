public import CmuxLinkWebRTC
public import CmuxPairing

/// B2's host-side check over the trust store: the key bound to the
/// device's DTLS fingerprint must be the install key of one of this
/// account's installs (and of the install the relay named, when it named one).
public struct TrustStoreWebRTCAuthorizer: WebRTCAuthorizer {
    private let mirror: TrustStoreMirror

    public init(mirror: TrustStoreMirror) {
        self.mirror = mirror
    }

    public func authorize(device: WebRTCPublicKey, install: String?) async -> Bool {
        guard let devices = await mirror.state?.devices else { return false }
        return devices.values.contains { candidate in
            (install == nil || install == candidate.install)
                && candidate.publicKey.signingKey?.x963Representation == device.x963Representation
        }
    }
}
