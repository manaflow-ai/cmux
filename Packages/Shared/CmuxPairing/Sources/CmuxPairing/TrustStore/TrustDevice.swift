/// One of this account's installs with its published link keys.
public struct TrustDevice: Hashable, Sendable, Codable {
    public var install: String
    public var kind: String
    public var name: String
    public var platform: String
    public var publicKey: InstallPublicKey
    /// The host this install enrolled (a Mac), confirmed by the owner.
    public var host: String?
    public var certs: TrustDeviceCerts
    public var updatedAt: Int64

    public init(install: String, kind: String, name: String, platform: String, publicKey: InstallPublicKey,
                host: String? = nil, certs: TrustDeviceCerts, updatedAt: Int64) {
        self.install = install
        self.kind = kind
        self.name = name
        self.platform = platform
        self.publicKey = publicKey
        self.host = host
        self.certs = certs
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case install, kind, name, platform, host, certs
        case publicKey = "public_jwk"
        case updatedAt = "updated_at"
    }
}
