/// `welcome` (cmux.wire/1): sent by a Durable Object right after the upgrade.
public struct WelcomeFrame: Hashable, Sendable, Codable {
    public var principal: [String: JSONValue]
    public var serverTime: Int64
    public var streams: [String]?

    public init(principal: [String: JSONValue], serverTime: Int64, streams: [String]? = nil) {
        self.principal = principal
        self.serverTime = serverTime
        self.streams = streams
    }

    enum CodingKeys: String, CodingKey {
        case principal, streams
        case serverTime = "server_time"
    }
}
