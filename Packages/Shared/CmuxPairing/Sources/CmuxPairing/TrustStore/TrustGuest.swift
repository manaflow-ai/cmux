/// Another account's device the owner accepted on one of this account's hosts.
public struct TrustGuest: Hashable, Sendable, Codable {
    public var offerID: String
    public var host: String
    public var team: String
    public var device: TrustPeer
    public var acceptedAt: Int64

    public init(offerID: String, host: String, team: String, device: TrustPeer, acceptedAt: Int64) {
        self.offerID = offerID
        self.host = host
        self.team = team
        self.device = device
        self.acceptedAt = acceptedAt
    }

    enum CodingKeys: String, CodingKey {
        case host, team
        case offerID = "offer_id"
        case acceptedAt = "accepted_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offerID = try c.decode(String.self, forKey: .offerID)
        host = try c.decode(String.self, forKey: .host)
        team = try c.decode(String.self, forKey: .team)
        acceptedAt = try c.decodeIfPresent(Int64.self, forKey: .acceptedAt) ?? 0
        device = try TrustPeer(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(offerID, forKey: .offerID)
        try c.encode(host, forKey: .host)
        try c.encode(team, forKey: .team)
        try c.encode(acceptedAt, forKey: .acceptedAt)
        try device.encode(to: encoder)
    }
}
