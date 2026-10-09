/// A cross-account claim waiting for the host owner's Accept or Decline.
public struct TrustRequest: Hashable, Sendable, Codable {
    /// base64url SHA-256 of the offer code (the code never reaches the stream).
    public var offerID: String
    public var host: String
    public var hostName: String
    public var team: String
    public var device: TrustPeer
    public var at: Int64
    public var expiresAt: Int64

    public init(offerID: String, host: String, hostName: String, team: String, device: TrustPeer, at: Int64, expiresAt: Int64) {
        self.offerID = offerID
        self.host = host
        self.hostName = hostName
        self.team = team
        self.device = device
        self.at = at
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case host, team, at
        case offerID = "offer_id"
        case hostName = "host_name"
        case expiresAt = "expires_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offerID = try c.decode(String.self, forKey: .offerID)
        host = try c.decode(String.self, forKey: .host)
        hostName = try c.decode(String.self, forKey: .hostName)
        team = try c.decode(String.self, forKey: .team)
        at = try c.decodeIfPresent(Int64.self, forKey: .at) ?? 0
        expiresAt = try c.decode(Int64.self, forKey: .expiresAt)
        device = try TrustPeer(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(offerID, forKey: .offerID)
        try c.encode(host, forKey: .host)
        try c.encode(hostName, forKey: .hostName)
        try c.encode(team, forKey: .team)
        try c.encode(at, forKey: .at)
        try c.encode(expiresAt, forKey: .expiresAt)
        try device.encode(to: encoder)
    }
}
