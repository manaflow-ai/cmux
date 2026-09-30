import Foundation

/// One record from an acpmux session log.
///
/// acpmux stores every message it exchanges with an agent plus its own `mux` records.
/// Backfill (`_acpmux/attach`, `_acpmux/events`) returns these records verbatim; live
/// delivery splits them into `session/update` and `_acpmux/event` notifications, which
/// ``init(liveSessionUpdate:)`` and ``init(liveMuxEvent:)`` fold back into this shape so
/// one reducer handles both paths.
public struct AcpmuxEventRecord: Sendable, Hashable, Codable, Identifiable {
    /// The acpmux session id. Absent on records read from older on-disk logs.
    public var sessionId: String?
    /// Per-session sequence number, starting at 1 and strictly increasing.
    public var seq: Int
    /// Unix time in milliseconds.
    public var at: Int64
    /// Direction: `in` (agent to acpmux), `out` (acpmux to agent), `mux`, or `peer`.
    public var dir: String
    /// The `sessionUpdate` value for agent updates, else the mux record kind.
    public var kind: String
    /// The raw payload. For `in` records this is the agent's JSON-RPC message.
    public var msg: JSONValue

    /// Stable identity within one session.
    public var id: Int { seq }

    /// Creates a record.
    public init(sessionId: String?, seq: Int, at: Int64, dir: String, kind: String, msg: JSONValue) {
        self.sessionId = sessionId
        self.seq = seq
        self.at = at
        self.dir = dir
        self.kind = kind
        self.msg = msg
    }

    /// Builds a record from the params of a live `session/update` notification.
    ///
    /// acpmux puts the sequence number in `_meta.acpmux.seq`. Returns `nil` when it is missing.
    public init?(liveSessionUpdate params: JSONValue) {
        guard let update = params["update"],
              let kind = update["sessionUpdate"]?.stringValue,
              let seq = params["_meta"]?["acpmux"]?["seq"]?.intValue else { return nil }
        let at = params["_meta"]?["acpmux"]?["at"]?.intValue ?? 0
        self.init(
            sessionId: params["sessionId"]?.stringValue,
            seq: seq,
            at: Int64(at),
            dir: "in",
            kind: kind,
            msg: .object([
                "jsonrpc": .string("2.0"),
                "method": .string("session/update"),
                "params": .object(["update": update]),
            ])
        )
    }

    /// Builds a record from the params of a live `_acpmux/event` notification.
    public init?(liveMuxEvent params: JSONValue) {
        guard let data = try? JSONEncoder().encode(params),
              let record = try? JSONDecoder().decode(AcpmuxEventRecord.self, from: data) else { return nil }
        self = record
    }

    /// The ACP `update` object when this is an agent `session/update` record.
    public var sessionUpdate: JSONValue? {
        guard dir == "in", msg["method"]?.stringValue == "session/update" else { return nil }
        return msg["params"]?["update"]
    }

    /// Whether this record replays history during `session/load` and must not render again.
    public var isReplay: Bool { kind.hasSuffix(".replay") }
}
