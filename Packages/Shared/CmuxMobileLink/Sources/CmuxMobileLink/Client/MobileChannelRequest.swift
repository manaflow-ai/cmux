import CmuxLink
import CmuxMobileWire

/// What `MobileLinkClient.open` declares: the A0 `channel.open` and the
/// link channel that carries it.
public struct MobileChannelRequest: Sendable {
    public var kind: ChannelKind
    public var channelClass: ChannelClass
    /// Credit granted to the host, in payload bytes (`channel.open.window`).
    public var window: UInt32
    public var params: [String: JSONValue]
    /// Link stream name, for example `terminal/term_ab12`.
    public var stream: String
    /// Link priority of this phone's sends (and the host's default).
    public var priority: ChannelPriority
    /// Link send budget of this phone's direction; nil uses the priority's default.
    public var budgetBytes: Int?

    public init(kind: ChannelKind, channelClass: ChannelClass, window: UInt32, params: [String: JSONValue],
                stream: String, priority: ChannelPriority, budgetBytes: Int? = nil) {
        self.kind = kind
        self.channelClass = channelClass
        self.window = window
        self.params = params
        self.stream = stream
        self.priority = priority
        self.budgetBytes = budgetBytes
    }
}
