/// `hello.ok`: the negotiated version and the caps both sides listed.
public struct HelloOKFrame: Hashable, Sendable, Codable {
    public var proto: String
    public var version: Int
    public var caps: [String]
    public var serverTime: Int64
    public var maxFrame: Int

    public init(version: Int, caps: [String], serverTime: Int64, maxFrame: Int) {
        self.proto = HelloFrame.proto
        self.version = version
        self.caps = caps
        self.serverTime = serverTime
        self.maxFrame = maxFrame
    }

    enum CodingKeys: String, CodingKey {
        case proto, version, caps
        case serverTime = "server_time"
        case maxFrame = "max_frame"
    }
}
