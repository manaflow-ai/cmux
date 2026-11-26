import Foundation

/// Client-held position in one collection's revision stream. Only meaningful
/// while the Mac's `epoch` is unchanged; a cursor from another epoch always
/// resolves to a snapshot.
public struct MobileSyncCursor: Codable, Equatable, Sendable {
    /// The store epoch this revision belongs to.
    public let epoch: String
    /// The last revision the client applied within that epoch.
    public let rev: UInt64

    /// Creates a cursor from its epoch and revision.
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
    /// How this section carries its records (snapshot or delta).
    public let mode: MobileSyncPayloadMode
    /// Head revision the payload brings the client to.
    public let rev: UInt64
    /// The client revision this delta starts from. Absent for snapshots.
    public let fromRev: UInt64?
    /// Changed (delta) or complete (snapshot) rows.
    public let records: [Record]
    /// Ids removed within the delta span. Empty for snapshots.
    public let removedIDs: [String]

    /// Creates one fetch-response section.
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
    /// One requested collection with the client's cursor, when it has one.
    public struct Collection: Codable, Equatable, Sendable {
        /// The collection being requested.
        public let id: MobileSyncCollectionID
        /// The cursor's epoch; absent on cold start.
        public let epoch: String?
        /// The cursor's revision; absent on cold start.
        public let rev: UInt64?

        /// Creates one request entry.
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

    /// The collections the client wants brought current.
    public let collections: [Collection]

    /// Creates a fetch request.
    public init(collections: [Collection]) {
        self.collections = collections
    }
}

/// The `mobile.sync.fetch` response body. Sections are optional so the shape
/// can grow collections without breaking older peers; a client ignores
/// sections it did not request and tolerates missing ones.
public struct MobileSyncFetchResponse: Codable, Equatable, Sendable {
    /// The store's current epoch; cursors are only meaningful within it.
    public let epoch: String
    /// The workspaces section, when requested.
    public let workspaces: MobileSyncCollectionPayload<WorkspaceSyncRecord>?
    /// The groups section, when requested.
    public let groups: MobileSyncCollectionPayload<GroupSyncRecord>?

    /// Creates a fetch response.
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
    /// The store epoch the revisions belong to.
    public let epoch: String
    /// The collection this delta mutates.
    public let collection: MobileSyncCollectionID
    /// The head revision before this tick.
    public let fromRev: UInt64
    /// The head revision after this tick.
    public let toRev: UInt64
    /// Full rows changed in this tick.
    public let records: [Record]
    /// Ids removed in this tick.
    public let removedIDs: [String]

    /// Creates one delta event.
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
    /// The collection the enclosing delta event mutates.
    public let collection: MobileSyncCollectionID

    /// Creates a header (primarily for tests; production decodes it).
    public init(collection: MobileSyncCollectionID) {
        self.collection = collection
    }
}

/// JSON bridging between the typed frames and the `[String: Any]` payloads the
/// mobile RPC envelope carries. One round-trip through `JSONSerialization` per
/// frame; frames are small (changed rows only), so this stays off every hot
/// path that matters. An instance type (not a namespace) so call sites can
/// hold and inject it.
public struct MobileSyncFrameCoder: Sendable {
    /// Creates a coder with the standard JSON strategies.
    public init() {}

    /// Encodes a typed frame into the RPC envelope's dictionary payload.
    public func jsonObject(from value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MobileSyncFrameCodingError.notAnObject
        }
        return object
    }

    /// Decodes a typed frame from the RPC envelope's dictionary payload.
    public func decode<Value: Decodable>(
        _ type: Value.Type,
        fromJSONObject object: [String: Any]
    ) throws -> Value {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }

    /// Decodes a typed frame from a JSON string (tests and fixtures).
    public func decode<Value: Decodable>(
        _ type: Value.Type,
        fromJSONString string: String
    ) throws -> Value {
        try JSONDecoder().decode(type, from: Data(string.utf8))
    }
}

/// Failure bridging a sync frame to or from the RPC envelope's JSON container.
public enum MobileSyncFrameCodingError: Error, Equatable, Sendable {
    /// The encoded frame was not a JSON object at the top level.
    case notAnObject
}
