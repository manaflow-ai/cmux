import Foundation

/// Client-held position in one collection's revision stream. Only meaningful
/// while the Mac's `epoch` is unchanged; a cursor from another epoch always
/// resolves to a snapshot.
public struct MobileSyncCursor: Codable, Equatable, Sendable {
    public let epoch: String
    public let rev: UInt64

    public init(epoch: String, rev: UInt64) {
        self.epoch = epoch
        self.rev = rev
    }
}

/// How a fetch response section carries its records.
public enum MobileSyncPayloadMode: String, Codable, Sendable {
    /// `records` is the full row set; replace local state.
    case snapshot
    /// `records`/`removed_ids` are changes in `(from_rev, rev]`; apply over
    /// local state at `from_rev` or newer.
    case delta
}

/// One collection section of a `mobile.sync.fetch` response.
public struct MobileSyncCollectionPayload<Record: MobileSyncRecord>: Codable, Equatable, Sendable {
    public let mode: MobileSyncPayloadMode
    /// Head revision the payload brings the client to.
    public let rev: UInt64
    /// The client revision this delta starts from. Absent for snapshots.
    public let fromRev: UInt64?
    public let records: [Record]
    public let removedIDs: [String]

    public init(
        mode: MobileSyncPayloadMode,
        rev: UInt64,
        fromRev: UInt64?,
        records: [Record],
        removedIDs: [String]
    ) {
        self.mode = mode
        self.rev = rev
        self.fromRev = fromRev
        self.records = records
        self.removedIDs = removedIDs
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case rev
        case fromRev = "from_rev"
        case records
        case removedIDs = "removed_ids"
    }
}

/// The `mobile.sync.fetch` request body: one cursor entry per collection the
/// client wants. A missing cursor means cold start (snapshot).
public struct MobileSyncFetchRequest: Codable, Equatable, Sendable {
    public struct Collection: Codable, Equatable, Sendable {
        public let id: MobileSyncCollectionID
        public let epoch: String?
        public let rev: UInt64?

        public init(id: MobileSyncCollectionID, epoch: String?, rev: UInt64?) {
            self.id = id
            self.epoch = epoch
            self.rev = rev
        }

        /// The cursor this entry carries, when it carries a complete one.
        public var cursor: MobileSyncCursor? {
            guard let epoch, let rev else { return nil }
            return MobileSyncCursor(epoch: epoch, rev: rev)
        }
    }

    public let collections: [Collection]

    public init(collections: [Collection]) {
        self.collections = collections
    }
}

/// The `mobile.sync.fetch` response body. Sections are optional so the shape
/// can grow collections without breaking older peers; a client ignores
/// sections it did not request and tolerates missing ones.
public struct MobileSyncFetchResponse: Codable, Equatable, Sendable {
    public let epoch: String
    public let workspaces: MobileSyncCollectionPayload<WorkspaceSyncRecord>?
    public let groups: MobileSyncCollectionPayload<GroupSyncRecord>?

    public init(
        epoch: String,
        workspaces: MobileSyncCollectionPayload<WorkspaceSyncRecord>?,
        groups: MobileSyncCollectionPayload<GroupSyncRecord>?
    ) {
        self.epoch = epoch
        self.workspaces = workspaces
        self.groups = groups
    }
}

/// One `mobile.sync.delta` event: the changes one producer tick made to one
/// collection. Applies iff the epoch matches and `from_rev <= local rev`
/// (idempotent overlap); `from_rev > local rev` is a gap the client repairs
/// with a cursor fetch.
public struct MobileSyncDeltaEvent<Record: MobileSyncRecord>: Codable, Equatable, Sendable {
    public let epoch: String
    public let collection: MobileSyncCollectionID
    public let fromRev: UInt64
    public let toRev: UInt64
    public let records: [Record]
    public let removedIDs: [String]

    public init(
        epoch: String,
        collection: MobileSyncCollectionID,
        fromRev: UInt64,
        toRev: UInt64,
        records: [Record],
        removedIDs: [String]
    ) {
        self.epoch = epoch
        self.collection = collection
        self.fromRev = fromRev
        self.toRev = toRev
        self.records = records
        self.removedIDs = removedIDs
    }

    private enum CodingKeys: String, CodingKey {
        case epoch
        case collection
        case fromRev = "from_rev"
        case toRev = "to_rev"
        case records
        case removedIDs = "removed_ids"
    }
}

/// Collection discriminator decoded before choosing the typed
/// `MobileSyncDeltaEvent` record type for a `mobile.sync.delta` payload.
public struct MobileSyncDeltaEventHeader: Codable, Equatable, Sendable {
    public let collection: MobileSyncCollectionID

    public init(collection: MobileSyncCollectionID) {
        self.collection = collection
    }
}

/// JSON bridging between the typed frames and the `[String: Any]` payloads the
/// mobile RPC envelope carries. One round-trip through `JSONSerialization` per
/// frame; frames are small (changed rows only), so this stays off every hot
/// path that matters.
public enum MobileSyncFrameJSON {
    public static func jsonObject(from value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MobileSyncFrameJSONError.notAnObject
        }
        return object
    }

    public static func decode<Value: Decodable>(
        _ type: Value.Type,
        fromJSONObject object: [String: Any]
    ) throws -> Value {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }

    public static func decode<Value: Decodable>(
        _ type: Value.Type,
        fromJSONString string: String
    ) throws -> Value {
        try JSONDecoder().decode(type, from: Data(string.utf8))
    }
}

/// Failure bridging a sync frame to or from the RPC envelope's JSON container.
public enum MobileSyncFrameJSONError: Error, Equatable, Sendable {
    case notAnObject
}
