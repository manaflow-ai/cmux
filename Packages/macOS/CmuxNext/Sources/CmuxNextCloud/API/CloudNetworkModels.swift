public import Foundation

public struct CloudFirewallEndpoint: Sendable, Hashable, Codable {
    public var vmId: String?
    public var vpcId: String?
    public var tunnelId: String?
    public var cidr: String?
    public var isPublic: Bool?
    public var port: Int?
    public var protocolName: String?

    enum CodingKeys: String, CodingKey { case vmId, vpcId, tunnelId, cidr, `public`, port, protocolName = "protocol" }
}

public struct CloudNetwork: Sendable, Hashable, Decodable {
    public var id: String
    public var cidr: String?
    public var cidrV6: String?
    public var scope: String
}

public struct CloudFirewallRule: Sendable, Hashable, Codable {
    public var id: String
    public var action: String
    public var source: CloudFirewallEndpoint
    public var destination: CloudFirewallEndpoint
    public var description: String?
}

public struct CloudTunnelNetworkMutation: Sendable, Hashable, Decodable {
    public var tunnelId: String
    public var networkId: String
    public var addressV4: String?
    public var addressV6: String?
    public var clientPublicKey: String?
    public var serverPublicKey: String?
    public var clientConfig: String?
}
