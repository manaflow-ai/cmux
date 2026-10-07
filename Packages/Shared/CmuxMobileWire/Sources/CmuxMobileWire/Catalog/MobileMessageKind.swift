/// How a catalog message travels (a0-rpc.md section 4).
public enum MobileMessageKind: String, CaseIterable, Hashable, Sendable, Codable {
    /// Client mutation, echoed as `event`.
    case op
    case read
    /// Committed only by the owner, seen as `event`.
    case owner
    /// A `channel.open` kind.
    case channel
    /// A JSON record on a channel.
    case message
    /// A binary record on a channel.
    case record
    /// An ephemeral relayed `signal` frame.
    case signal
}
