public import Foundation

public struct CloudTunnelNetworkMutation: Sendable, Hashable, Decodable {
    public var tunnelId: String
    public var networkId: String
    public var addressV4: String?
    public var addressV6: String?
    public var clientPublicKey: String?
    public var serverPublicKey: String?
    public var clientConfig: String?
}
