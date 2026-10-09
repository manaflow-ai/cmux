/// Another account's device in a pending request or an accepted guest grant.
public struct TrustPeer: Hashable, Sendable, Codable {
    public var install: String
    public var user: String
    public var userName: String
    public var name: String
    public var platform: String
    public var publicKey: InstallPublicKey
    public var cert: LinkCertificate

    public init(install: String, user: String, userName: String, name: String, platform: String,
                publicKey: InstallPublicKey, cert: LinkCertificate) {
        self.install = install
        self.user = user
        self.userName = userName
        self.name = name
        self.platform = platform
        self.publicKey = publicKey
        self.cert = cert
    }

    enum CodingKeys: String, CodingKey {
        case install, user, name, platform, cert
        case userName = "user_name"
        case publicKey = "public_jwk"
    }
}
