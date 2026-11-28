public import Foundation

public struct CloudFirewallEndpoint: Sendable, Hashable, Codable {
    public var vmId: String?
    public var vpcId: String?
    public var tunnelId: String?
    public var cidr: String?
    public var isPublic: Bool?
    public var port: Int?
    public var protocolName: String?

    enum CodingKeys: String, CodingKey { case vmId, vpcId, tunnelId, cidr, isPublic = "public", port, protocolName = "protocol" }
}
