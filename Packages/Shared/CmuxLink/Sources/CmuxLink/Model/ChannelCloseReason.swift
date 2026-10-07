/// Why a channel ended.
public enum ChannelCloseReason: Sendable, Hashable {
    case local
    case remote
    case sessionClosed(LinkCloseReason)
}
