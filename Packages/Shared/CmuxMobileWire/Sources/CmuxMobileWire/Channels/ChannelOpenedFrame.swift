/// `channel.opened`: the owner accepted; `resumed` false means start fresh (terminals: a new snapshot).
public struct ChannelOpenedFrame: Hashable, Sendable, Codable {
    public var channel: UInt32
    public var window: UInt32
    public var params: [String: JSONValue]
    public var resumed: Bool

    public init(channel: UInt32, window: UInt32, params: [String: JSONValue], resumed: Bool) {
        self.channel = channel
        self.window = window
        self.params = params
        self.resumed = resumed
    }
}
