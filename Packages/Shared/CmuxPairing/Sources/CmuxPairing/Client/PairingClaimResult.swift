/// What the owner answers to `pairing.claim` (b6-pairing.md section 4.2).
public struct PairingClaimResult: Hashable, Sendable, Codable {
    public var status: PairingClaimStatus
    public var offerID: String
    public var host: String
    public var team: String
    /// The host's name as the owner records it (show this, not the link's `n`).
    public var name: String
    public var ownerUser: String
    public var hostInstall: String
    public var hostKey: InstallPublicKey
    public var hostCertificate: LinkCertificate

    enum CodingKeys: String, CodingKey {
        case status, host, team, name
        case offerID = "offer_id"
        case ownerUser = "owner_user"
        case hostInstall = "host_install"
        case hostKey = "host_jwk"
        case hostCertificate = "host_cert"
    }

    /// Verifies the host cert against the host install key and checks it pins
    /// the key the QR code carried (defense against a lying owner).
    public func verify(offer: PairingOffer, environment: String, now: Int64) throws(LinkCertificateError) {
        guard hostCertificate.purpose == .direct else { throw .wrongPurpose }
        guard hostCertificate.install == hostInstall else { throw .wrongInstall }
        guard hostCertificate.user == ownerUser else { throw .wrongUser }
        guard hostCertificate.key == offer.hostKey, let signing = hostKey.signingKey else { throw .badKey }
        try hostCertificate.verify(installKey: signing, environment: environment, now: now)
    }
}
