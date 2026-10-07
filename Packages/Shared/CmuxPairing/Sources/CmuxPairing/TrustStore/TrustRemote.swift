/// Another account's host one of this account's devices was accepted on.
public struct TrustRemote: Hashable, Sendable, Codable {
    public var host: String
    public var team: String
    public var ownerUser: String
    public var name: String
    public var hostInstall: String
    public var publicKey: InstallPublicKey
    /// The host's `direct` cert, signed by `publicKey`.
    public var cert: LinkCertificate
    /// This account's device the owner accepted.
    public var install: String
    public var offerID: String
    public var acceptedAt: Int64

    public init(host: String, team: String, ownerUser: String, name: String, hostInstall: String, publicKey: InstallPublicKey,
                cert: LinkCertificate, install: String, offerID: String, acceptedAt: Int64) {
        self.host = host
        self.team = team
        self.ownerUser = ownerUser
        self.name = name
        self.hostInstall = hostInstall
        self.publicKey = publicKey
        self.cert = cert
        self.install = install
        self.offerID = offerID
        self.acceptedAt = acceptedAt
    }

    enum CodingKeys: String, CodingKey {
        case host, team, name, cert, install
        case ownerUser = "owner_user"
        case hostInstall = "host_install"
        case publicKey = "public_jwk"
        case offerID = "offer_id"
        case acceptedAt = "accepted_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        team = try c.decode(String.self, forKey: .team)
        ownerUser = try c.decode(String.self, forKey: .ownerUser)
        name = try c.decode(String.self, forKey: .name)
        hostInstall = try c.decode(String.self, forKey: .hostInstall)
        publicKey = try c.decode(InstallPublicKey.self, forKey: .publicKey)
        cert = try c.decode(LinkCertificate.self, forKey: .cert)
        install = try c.decode(String.self, forKey: .install)
        offerID = try c.decode(String.self, forKey: .offerID)
        acceptedAt = try c.decodeIfPresent(Int64.self, forKey: .acceptedAt) ?? 0
    }
}
