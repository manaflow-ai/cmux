/// `channel.closed`: the owner's final word on a channel (also unsolicited, for example kicked).
public struct ChannelClosedFrame: Hashable, Sendable, Codable {
    public var channel: UInt32
    public var code: String?
    public var message: String?

    public init(channel: UInt32, code: String? = nil, message: String? = nil) {
        self.channel = channel
        self.code = code
        self.message = message
    }
}
