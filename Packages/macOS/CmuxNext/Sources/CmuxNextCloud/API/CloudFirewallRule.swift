public import Foundation

public struct CloudFirewallRule: Sendable, Hashable, Codable {
    public var id: String
    public var action: String
    public var source: CloudFirewallEndpoint
    public var destination: CloudFirewallEndpoint
    public var description: String?
}
