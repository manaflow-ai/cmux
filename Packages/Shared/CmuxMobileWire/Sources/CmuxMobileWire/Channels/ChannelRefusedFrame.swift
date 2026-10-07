/// `channel.refused`: the open failed, in the shared error shape.
public struct ChannelRefusedFrame: Hashable, Sendable, Codable {
    public var channel: UInt32
    public var code: String
    public var message: String
    public var retryable: Bool
    public var details: JSONValue?

    public init(channel: UInt32, code: String, message: String, retryable: Bool, details: JSONValue? = nil) {
        self.channel = channel
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}
