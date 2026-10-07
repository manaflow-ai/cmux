import CmuxMobileWire

/// A channel the host accepted, with its `channel.opened` answer and the
/// client session generation it belongs to (a later generation means this
/// channel's session is gone).
public struct MobileOpenedChannel: Sendable {
    public let channel: MobileChannel
    public let opened: ChannelOpenedFrame
    public let generation: UInt64

    public init(channel: MobileChannel, opened: ChannelOpenedFrame, generation: UInt64) {
        self.channel = channel
        self.opened = opened
        self.generation = generation
    }
}
