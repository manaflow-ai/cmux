/// What a channel delivers to its consumer, in order.
public enum ChannelEvent: Sendable, Hashable {
    case message(LinkMessage)
    case gap(ChannelGap)
    /// Last event; the sequence ends after it.
    case closed(ChannelCloseReason)
}
