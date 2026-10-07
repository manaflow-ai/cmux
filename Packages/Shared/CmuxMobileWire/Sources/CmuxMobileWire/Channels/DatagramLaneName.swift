/// The link stream name of a datagram lane paired with an A0 channel
/// (c2-browser-stream.md section 2): `cmux.mobile/datagram/<channel id>`.
/// The lane is an unreliable link channel the phone opens with no
/// `channel.open` record; its records carry the paired channel's id, their
/// own per-direction seq, and gaps are loss.
public struct DatagramLaneName: Hashable, Sendable {
    public static let prefix = "cmux.mobile/datagram/"

    /// The paired A0 channel.
    public var channel: UInt32

    public init(channel: UInt32) {
        self.channel = channel
    }

    /// Parses a link stream name; nil when it does not name a datagram lane.
    public init?(stream: String) {
        guard stream.hasPrefix(Self.prefix), let id = UInt32(stream.dropFirst(Self.prefix.count)) else { return nil }
        channel = id
    }

    public var stream: String { Self.prefix + String(channel) }
}
