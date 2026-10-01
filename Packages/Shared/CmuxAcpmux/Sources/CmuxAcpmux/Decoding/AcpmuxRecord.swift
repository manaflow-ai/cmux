public import CmuxConversation

/// One entry of an acpmux session log, however it arrived: in a history
/// page (`_acpmux/attach`, `_acpmux/events`), as a live `_acpmux/event`, or
/// as a live `session/update` notification.
public struct AcpmuxRecord: Hashable, Sendable {
    /// The session's sequence number for the entry.
    public var seq: UInt64
    /// When it was recorded, in milliseconds since 1970.
    public var at: UInt64?
    /// `in` (agent to acpmux), `out` (acpmux to agent) or `mux` (acpmux's own).
    public var dir: String
    /// The method, update kind, or acpmux record kind.
    public var kind: String
    /// The raw JSON-RPC message (`in`/`out`) or acpmux payload (`mux`).
    public var msg: JSONValue

    /// Creates a record.
    /// - Parameters:
    ///   - seq: Sequence number.
    ///   - at: Recording time in milliseconds.
    ///   - dir: Direction.
    ///   - kind: Kind.
    ///   - msg: Payload.
    public init(seq: UInt64, at: UInt64?, dir: String, kind: String, msg: JSONValue) {
        self.seq = seq
        self.at = at
        self.dir = dir
        self.kind = kind
        self.msg = msg
    }

    /// Reads a record from a history page entry or an `_acpmux/event`.
    /// - Parameter value: The entry.
    public init?(event value: JSONValue) {
        guard let seq = value["seq"]?.uint64Value else { return nil }
        self.init(seq: seq, at: value["at"]?.uint64Value, dir: value["dir"]?.stringValue ?? "", kind: value["kind"]?.stringValue ?? "", msg: value["msg"] ?? .null)
    }

    /// Reads a record from a live `session/update` notification's parameters.
    /// - Parameter params: The notification parameters (with `_meta.acpmux.seq`).
    public init?(update params: JSONValue) {
        guard let meta = params["_meta"]?["acpmux"], let seq = meta["seq"]?.uint64Value else { return nil }
        let kind = params["update"]?["sessionUpdate"]?.stringValue ?? "session/update"
        self.init(seq: seq, at: meta["at"]?.uint64Value, dir: "in", kind: kind, msg: .object(["method": .string("session/update"), "params": params]))
    }
}
