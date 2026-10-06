public import Foundation

/// A message the transport handles itself rather than the decoder.
public nonisolated enum RemoteRdMessage: Sendable, Hashable {
    /// A control message (JSON) from the stream carrier.
    case control(Data)
    /// A datagram that is not a video shard (input ack, cursor position,
    /// audio, probe), header included.
    case datagram(Data)
}
