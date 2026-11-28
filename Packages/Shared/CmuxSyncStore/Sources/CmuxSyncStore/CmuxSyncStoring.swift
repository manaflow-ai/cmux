public import Foundation

/// One stored sync record as the store returns it. The `payloadJSON` is the
/// opaque collection body; a typed facade decodes it. Tombstones have
/// `deleted == true` and `payloadJSON == "{}"`.
public struct StoredSyncRecord: Equatable, Sendable {
    public let collection: String
    public let recordID: String
    public let rev: Int
    /// Epoch SECONDS (the store's column unit; the wire `updatedAt` ms is
    /// divided by 1000 on write — the single unit boundary, DESIGN.md §4.1).
    public let updatedAt: Double
    public let sortKey: Double
    public let deleted: Bool
    public let payloadJSON: Data

    public init(collection: String, recordID: String, rev: Int, updatedAt: Double, sortKey: Double, deleted: Bool, payloadJSON: Data) {
        self.collection = collection
        self.recordID = recordID
        self.rev = rev
        self.updatedAt = updatedAt
        self.sortKey = sortKey
        self.deleted = deleted
        self.payloadJSON = payloadJSON
    }
}

/// The local-first sync store seam. One generic SQLite database with a
/// collection-agnostic `sync_records` + `sync_cursors` schema (DESIGN.md §4).
/// Higher layers depend on `any CmuxSyncStoring` so a test double can stand in.
///
/// All applies are atomic per frame: `applyFrame` commits the records and the
/// cursor in one transaction, so the cursor only ever names a rev below which
/// the client provably has everything (the contiguous-prefix watermark,
/// DESIGN.md §3.1a). A crash before commit re-pulls the frame.
public protocol CmuxSyncStoring: Sendable {
    /// Live (non-tombstone) records of a collection for a team, in render order
    /// (`sort_key DESC`). The launch read; no network. (DESIGN.md §3.3 t0)
    func liveRecords(teamID: String, collection: String) async throws -> [StoredSyncRecord]

    /// The durable cursor (contiguous-prefix watermark) for a (team, collection),
    /// 0 if none. Sent in `sync.hello`. (DESIGN.md §3.1a)
    func cursor(teamID: String, collection: String) async throws -> Int

    /// The history generation the client last synced against for a
    /// (team, collection), 0 if none. Sent in `sync.hello` so the server can
    /// detect a DO storage reset even at an equal head. (DESIGN.md §3.6)
    func epoch(teamID: String, collection: String) async throws -> Int

    /// Apply one delta or tick frame atomically: upsert/tombstone each record by
    /// the `local.rev >= r.rev` guard, then advance the cursor to `frameRev`.
    /// (DESIGN.md §3.2 applyFrame)
    func applyDelta(
        teamID: String,
        collection: String,
        frameRev: Int,
        records: [SyncWireRecord],
        sortKeyFor: @Sendable (SyncWireRecord) -> Double,
        now: Date
    ) async throws

    /// Apply a completed snapshot atomically: upsert each record, run the
    /// `rev >= 1` reconciliation (drop local authoritative records absent from
    /// the snapshot), then set the cursor to `snapshotRev`. Provisional `rev == 0`
    /// migration rows are exempt from reconciliation. (DESIGN.md §3.2a/§6)
    func applySnapshot(
        teamID: String,
        collection: String,
        snapshotRev: Int,
        epoch: Int,
        records: [SyncWireRecord],
        sortKeyFor: @Sendable (SyncWireRecord) -> Double,
        now: Date
    ) async throws

    /// Seed a provisional record (`rev == 0`) for the transparent migration. A
    /// no-op if a record (provisional or authoritative) already exists for the
    /// id, so re-running on each sign-in is idempotent. (DESIGN.md §6)
    func seedProvisional(
        teamID: String,
        collection: String,
        recordID: String,
        payloadJSON: Data,
        sortKey: Double,
        now: Date
    ) async throws

    /// Whether the one-time migration seeding has already run for an
    /// (account, team) scope. Keyed by both because the seeded provisional rows
    /// are team-scoped: the same account in a different team must still seed that
    /// team's rows. (DESIGN.md §6 idempotency key)
    func migrationCompleted(accountID: String, teamID: String) async throws -> Bool
    /// Record that migration seeding ran for an (account, team) scope.
    func markMigrationCompleted(accountID: String, teamID: String) async throws

    /// Clear all synced state for a team (sign-out of that scope), INCLUDING its
    /// migration markers, so a re-sign-in re-seeds the fallback. (DESIGN.md §11)
    func clear(teamID: String) async throws
}
