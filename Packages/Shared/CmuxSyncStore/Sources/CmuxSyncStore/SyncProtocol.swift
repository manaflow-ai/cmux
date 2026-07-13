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
    /// Full state of a collection as of `snapshotRev`, in history generation
    /// `epoch`. Paged: commit only on the `complete` page. A snapshot whose epoch
    /// differs from the client's stored epoch is a reset and is applied
    /// authoritatively. (DESIGN.md §3.2/§3.4/§3.6)
    case snapshot(collection: String, snapshotRev: Int, epoch: Int, records: [SyncWireRecord], complete: Bool)
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

/// Encodes/decodes sync/v1 wire frames. An instantiable value (not a static
/// namespace) per the package conventions; construct once and reuse.
public struct SyncFrameCodec: Sendable {
    public init() {}

    /// Parse one WS text/data frame. Returns `.unknown` for non-sync frames
    /// (so the caller routes presence frames elsewhere) and only throws on a
    /// frame that claims to be sync but is structurally broken.
    public func parse(_ data: Data) throws -> SyncServerFrame {
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
            let epoch = intValue(obj["epoch"]) ?? 0
            return .snapshot(
                collection: collection,
                snapshotRev: snapshotRev,
                epoch: epoch,
                records: try requireRecords(obj["records"], frame: "sync.snapshot", maxRev: snapshotRev),
                complete: complete
            )
        case "sync.delta":
            guard let collection = obj["collection"] as? String,
                  let rev = intValue(obj["rev"]) else {
                throw SyncFrameParseError.malformed("sync.delta missing collection/rev")
            }
            return .delta(collection: collection, rev: rev, records: try requireRecords(obj["records"], frame: "sync.delta", maxRev: rev))
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
    /// collections with the cursors and epochs it already holds (DESIGN.md §3.2).
    public func encodeHello(collections: [(name: String, cursor: Int, epoch: Int)]) throws -> Data {
        let payload: [String: Any] = [
            "type": "sync.hello",
            "protocol": syncProtocolV1,
            "collections": collections.map { ["name": $0.name, "cursor": $0.cursor, "epoch": $0.epoch] },
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// Records for a delta/snapshot frame. The field is REQUIRED and must be an
    /// array: a frame that claims to be sync but whose `records` is missing or
    /// the wrong type is structurally broken and throws, so the client
    /// reconnects/resyncs rather than committing an empty frame that would
    /// silently advance the cursor (or reconcile against an empty snapshot set)
    /// and durably lose records.
    ///
    /// `maxRev` is the frame head (`rev` for a delta, `snapshotRev` for a
    /// snapshot). The DO never emits a record whose rev exceeds the head it is
    /// advancing the cursor to, so a record with `record.rev > maxRev` is a
    /// malformed/forged frame. Reject it: persisting it would write a poison-high
    /// rev whose per-record monotone guard then ignores every legitimate future
    /// update for that id until the server's head finally catches up (a durable
    /// local-cache poisoning). Throwing forces a clean resync instead.
    private func requireRecords(_ value: Any?, frame: String, maxRev: Int) throws -> [SyncWireRecord] {
        guard let array = value as? [[String: Any]] else {
            throw SyncFrameParseError.malformed("\(frame) missing or non-array records")
        }
        return try array.map {
            let record = try parseRecord($0)
            guard record.rev <= maxRev else {
                throw SyncFrameParseError.malformed("\(frame) record \(record.id) rev \(record.rev) exceeds frame head \(maxRev)")
            }
            return record
        }
    }

    private func parseRecord(_ obj: [String: Any]) throws -> SyncWireRecord {
        guard let id = obj["id"] as? String, let rev = intValue(obj["rev"]) else {
            throw SyncFrameParseError.malformed("record missing id/rev")
        }
        let updatedAt = doubleValue(obj["updatedAt"]) ?? 0
        let deleted = (obj["deleted"] as? Bool) ?? false
        let schemaVersion = intValue(obj["schemaVersion"]) ?? syncSchemaVersion
        let payloadJSON: Data
        if deleted {
            // A tombstone legitimately carries `{}`; its payload is never read.
            payloadJSON = Data("{}".utf8)
        } else {
            // A LIVE record must carry a serializable payload. If it is missing or
            // unserializable, do NOT silently store `{}` (which the facade cannot
            // decode, hiding the row while the cursor advances past it). Throw
            // .malformed so the client resyncs instead of durably losing the row.
            guard let payload = obj["payload"],
                  let serialized = try? JSONSerialization.data(withJSONObject: payload) else {
                throw SyncFrameParseError.malformed("live record \(id) missing/unserializable payload")
            }
            payloadJSON = serialized
        }
        return SyncWireRecord(
            id: id,
            rev: rev,
            updatedAt: updatedAt,
            deleted: deleted,
            schemaVersion: schemaVersion,
            payloadJSON: payloadJSON
        )
    }

    /// Parse a NON-NEGATIVE integer from a JSON value. `rev`/`snapshotRev`/
    /// `cursor`/`epoch` are all non-negative, so a negative or non-integral value
    /// is malformed. A JSON boolean (which `JSONSerialization` bridges to a
    /// CFBoolean-backed `NSNumber`) is rejected too, so `rev: true` does not parse
    /// as 1. Returns nil for anything invalid so the caller surfaces `.malformed`.
    private func intValue(_ value: Any?) -> Int? {
        // Reject JSON booleans: an NSNumber backed by CFBoolean has the Bool
        // ObjC type, and `true as? Int` would otherwise yield 1.
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            return nil
        }
        let parsed: Int?
        if let i = value as? Int {
            parsed = i
        } else if let d = value as? Double {
            // Route through Double bounds-checking so a huge value (e.g. 1e100)
            // yields nil instead of trapping on an out-of-range Int conversion.
            parsed = intFromDouble(d)
        } else if let n = value as? NSNumber {
            parsed = intFromDouble(n.doubleValue)
        } else {
            parsed = nil
        }
        guard let result = parsed, result >= 0 else { return nil }
        return result
    }

    /// Convert a JSON double to Int only when it is finite, integral, and within
    /// Int range; otherwise nil so the caller surfaces `.malformed` and resyncs
    /// rather than trapping the process on `Int(d)` overflow.
    ///
    /// `Int.max` (2^63 - 1) is NOT exactly representable as a Double — it rounds
    /// up to 2^63 — so comparing `d <= Double(Int.max)` would let `2^63` through
    /// and then trap on `Int(d)`. Compare against the exactly-representable power
    /// of two `2^63` with a STRICT `<`, and against `-2^63` (which IS exactly
    /// representable and equals `Int.min`) with `>=`.
    private func intFromDouble(_ d: Double) -> Int? {
        let twoTo63 = 9223372036854775808.0 // 2^63, exact in Double; > Int.max
        guard d.isFinite, d == d.rounded(.towardZero),
              d >= -twoTo63, d < twoTo63 else {
            return nil
        }
        return Int(d)
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
