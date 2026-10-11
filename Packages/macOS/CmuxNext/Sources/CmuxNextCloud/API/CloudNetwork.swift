public import Foundation

public struct CloudNetwork: Sendable, Hashable, Decodable {
    public var id: String
    public var cidr: String?
    public var cidrV6: String?
    public var scope: String
}
