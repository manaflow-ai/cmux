/// `channel.open` on channel 0. The dialing side opens odd ids, the accepting side even ids.
public struct ChannelOpenFrame: Hashable, Sendable, Codable {
    public var channel: UInt32
    public var kind: ChannelKind
    public var channelClass: ChannelClass
    /// Initial credit the opener grants the peer, in payload bytes.
    public var window: UInt32
    public var params: [String: JSONValue]
    public var resume: ChannelResume?

    public init(channel: UInt32, kind: ChannelKind, channelClass: ChannelClass, window: UInt32,
                params: [String: JSONValue], resume: ChannelResume? = nil) {
        self.channel = channel
        self.kind = kind
        self.channelClass = channelClass
        self.window = window
        self.params = params
        self.resume = resume
    }

    enum CodingKeys: String, CodingKey {
        case channel, kind, window, params, resume
        case channelClass = "class"
    }
}
