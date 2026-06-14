public import Foundation

/// The sync/v1 wire protocol, Swift side. Mirrors `workers/presence/src/sync.ts`
/// exactly: the same frame shapes the DO emits over the presence WebSocket. See
/// plans/feat-do-device-list/DESIGN.md §3.
///
/// The payload is opaque to this layer (stored as raw JSON); typed facades
/// decode it. Decoding here is defensive: a frame the client does not understand
/// is surfaced as `.unknown` rather than throwing, so an old client never
/// crashes on a future frame type and a sync frame interleaved with presence
/// frames on the shared socket is cleanly separable.

/// Current sync record schema version. Must match `SYNC_SCHEMA_VERSION` in the
/// worker. A stored record below this is lazily upgraded server-side.
public let syncSchemaVersion = 1

/// The sync protocol identifier sent in `sync.hello`.
public let syncProtocolV1 = "sync/v1"

/// One synced record as it appears on the wire and is stored locally. The
/// `payload` is kept as raw JSON bytes so the transport/store never decode it;
/// the typed facade decodes on read.
public struct SyncWireRecord: Equatable, Sendable {
    public let id: String
    public let rev: Int
    /// Epoch ms the DO last wrote this record (tiebreak/debug only; `rev` orders).
    public let updatedAt: Double
    public let deleted: Bool
    public let schemaVersion: Int
    /// Opaque collection-typed JSON body, `{}` for tombstones. Stored verbatim.
    public let payloadJSON: Data

    public init(id: String, rev: Int, updatedAt: Double, deleted: Bool, schemaVersion: Int, payloadJSON: Data) {
        self.id = id
        self.rev = rev
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.schemaVersion = schemaVersion
        self.payloadJSON = payloadJSON
    }
}

/// A server → client sync frame. `unknown` covers any non-sync frame on the
/// shared socket (the presence frames) and any future sync frame type, so the
/// dispatcher can ignore it without error.
public enum SyncServerFrame: Equatable, Sendable {
    /// Full state of a collection as of `snapshotRev`. Paged: commit only on the
    /// `complete` page. (DESIGN.md §3.2/§3.4)
    case snapshot(collection: String, snapshotRev: Int, records: [SyncWireRecord], complete: Bool)
    /// Incremental change(s); `rev` is the head this frame advances the cursor
    /// to once fully applied. (DESIGN.md §3.2)
    case delta(collection: String, rev: Int, records: [SyncWireRecord])
    /// Liveness + cursor tick when nothing record-shaped changed. (DESIGN.md §3.2)
    case tick(collection: String, rev: Int)
    /// Not a sync frame this client handles (a presence frame, or a future type).
    case unknown
}

public enum SyncFrameParseError: Error, Equatable, Sendable {
    case notJSON
    case malformed(String)
}

public enum SyncFrameCodec {
    /// Parse one WS text/data frame. Returns `.unknown` for non-sync frames
    /// (so the caller routes presence frames elsewhere) and only throws on a
    /// frame that claims to be sync but is structurally broken.
    public static func parse(_ data: Data) throws -> SyncServerFrame {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncFrameParseError.notJSON
        }
        guard let type = obj["type"] as? String else { return .unknown }
        switch type {
        case "sync.snapshot":
            guard let collection = obj["collection"] as? String,
                  let snapshotRev = intValue(obj["snapshotRev"]) else {
                throw SyncFrameParseError.malformed("sync.snapshot missing collection/snapshotRev")
            }
            let complete = (obj["complete"] as? Bool) ?? false
            return .snapshot(
                collection: collection,
                snapshotRev: snapshotRev,
                records: try requireRecords(obj["records"], frame: "sync.snapshot"),
                complete: complete
            )
        case "sync.delta":
            guard let collection = obj["collection"] as? String,
                  let rev = intValue(obj["rev"]) else {
                throw SyncFrameParseError.malformed("sync.delta missing collection/rev")
            }
            return .delta(collection: collection, rev: rev, records: try requireRecords(obj["records"], frame: "sync.delta"))
        case "sync.tick":
            guard let collection = obj["collection"] as? String,
                  let rev = intValue(obj["rev"]) else {
                throw SyncFrameParseError.malformed("sync.tick missing collection/rev")
            }
            return .tick(collection: collection, rev: rev)
        default:
            // A presence frame (snapshot/online/offline/seen/routes) or a future
            // sync frame: not ours to apply.
            return .unknown
        }
    }

    /// Encode the `sync.hello` a client sends after connect to subscribe to
    /// collections with the cursors it already holds (DESIGN.md §3.2).
    public static func encodeHello(collections: [(name: String, cursor: Int)]) throws -> Data {
        let payload: [String: Any] = [
            "type": "sync.hello",
            "protocol": syncProtocolV1,
            "collections": collections.map { ["name": $0.name, "cursor": $0.cursor] },
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// Records for a delta/snapshot frame. The field is REQUIRED and must be an
    /// array: a frame that claims to be sync but whose `records` is missing or
    /// the wrong type is structurally broken and throws, so the client
    /// reconnects/resyncs rather than committing an empty frame that would
    /// silently advance the cursor (or reconcile against an empty snapshot set)
    /// and durably lose records.
    private static func requireRecords(_ value: Any?, frame: String) throws -> [SyncWireRecord] {
        guard let array = value as? [[String: Any]] else {
            throw SyncFrameParseError.malformed("\(frame) missing or non-array records")
        }
        return try array.map { try parseRecord($0) }
    }

    private static func parseRecord(_ obj: [String: Any]) throws -> SyncWireRecord {
        guard let id = obj["id"] as? String, let rev = intValue(obj["rev"]) else {
            throw SyncFrameParseError.malformed("record missing id/rev")
        }
        let updatedAt = doubleValue(obj["updatedAt"]) ?? 0
        let deleted = (obj["deleted"] as? Bool) ?? false
        let schemaVersion = intValue(obj["schemaVersion"]) ?? syncSchemaVersion
        let payload = obj["payload"] ?? [:]
        let payloadJSON = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return SyncWireRecord(
            id: id,
            rev: rev,
            updatedAt: updatedAt,
            deleted: deleted,
            schemaVersion: schemaVersion,
            payloadJSON: payloadJSON
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
