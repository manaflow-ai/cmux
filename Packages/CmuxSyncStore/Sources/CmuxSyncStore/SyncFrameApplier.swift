public import Foundation

/// The client-side frame application state machine (DESIGN.md §3.2/§3.4). Drives
/// a `CmuxSyncStoring` from a stream of `SyncServerFrame`s, handling the
/// snapshot-paging buffer and the concurrent-delta queue so a delete racing a
/// snapshot is never lost.
///
/// Factored out of the WS transport so it is unit-testable with synthetic frames
/// and a real (temp-file) store. The transport just feeds `apply(_:)` and reads
/// `cursor(teamID:collection:)` to build the next `sync.hello`.
///
/// One applier instance handles one team's subscription. It is an actor: frames
/// arrive serially from the receive loop, and the applier serializes the
/// store writes and its own page/queue buffers.
public actor SyncFrameApplier {
    private let store: any CmuxSyncStoring
    private let teamID: String
    private let sortKeyFor: @Sendable (SyncWireRecord) -> Double
    private let now: @Sendable () -> Date

    /// Per-collection in-flight snapshot: accumulated pages + the deltas that
    /// arrived during paging (queued, applied after the snapshot commits).
    private struct SnapshotBuild {
        var snapshotRev: Int
        var records: [SyncWireRecord] = []
        var queuedDeltas: [(rev: Int, records: [SyncWireRecord])] = []
    }
    private var builds: [String: SnapshotBuild] = [:]

    public init(
        store: any CmuxSyncStoring,
        teamID: String,
        sortKeyFor: @escaping @Sendable (SyncWireRecord) -> Double,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.teamID = teamID
        self.sortKeyFor = sortKeyFor
        self.now = now
    }

    /// The cursor to send in the next `sync.hello` for a collection.
    public func cursor(collection: String) async throws -> Int {
        try await store.cursor(teamID: teamID, collection: collection)
    }

    /// Apply one server frame. Snapshot pages buffer until `complete`; deltas
    /// received mid-paging are queued and drained after the snapshot commits;
    /// deltas/ticks outside paging apply immediately. `.unknown` (a presence
    /// frame) is ignored.
    public func apply(_ frame: SyncServerFrame) async throws {
        switch frame {
        case let .snapshot(collection, snapshotRev, records, complete):
            try await applySnapshotPage(collection: collection, snapshotRev: snapshotRev, records: records, complete: complete)
        case let .delta(collection, rev, records):
            try await applyDeltaFrame(collection: collection, rev: rev, records: records)
        case let .tick(collection, rev):
            // A tick advances the cursor when nothing record-shaped changed. Safe
            // because the DO guarantees it has sent every record up to head
            // (DESIGN.md §3.2). During paging, a tick is ignored (the snapshot
            // commit sets the cursor); otherwise apply as an empty delta.
            if builds[collection] == nil {
                try await store.applyDelta(
                    teamID: teamID, collection: collection, frameRev: rev,
                    records: [], sortKeyFor: sortKeyFor, now: now()
                )
            }
        case .unknown:
            break // presence frame or future type; not ours
        }
    }

    /// Discard any in-flight snapshot build for a collection on a stream drop, so
    /// a half-applied snapshot never commits; the reconnect re-hellos and gets a
    /// fresh snapshot (DESIGN.md §3.4).
    public func resetInFlight() {
        builds.removeAll()
    }

    private func applySnapshotPage(collection: String, snapshotRev: Int, records: [SyncWireRecord], complete: Bool) async throws {
        var build = builds[collection] ?? SnapshotBuild(snapshotRev: snapshotRev)
        // A snapshotRev change mid-paging means the server restarted the
        // snapshot; discard the stale buffer and start fresh.
        if build.snapshotRev != snapshotRev {
            build = SnapshotBuild(snapshotRev: snapshotRev)
        }
        build.records.append(contentsOf: records)
        if !complete {
            builds[collection] = build
            return
        }
        // Commit the full snapshot atomically (upserts + rev>=1 reconciliation +
        // cursor = snapshotRev), then drain the deltas that raced the paging.
        try await store.applySnapshot(
            teamID: teamID, collection: collection, snapshotRev: snapshotRev,
            records: build.records, sortKeyFor: sortKeyFor, now: now()
        )
        let queued = build.queuedDeltas
        builds[collection] = nil
        for delta in queued {
            // Only revs above the snapshot matter; lower ones are already in the
            // snapshot and the store's local.rev guard ignores them anyway.
            try await store.applyDelta(
                teamID: teamID, collection: collection, frameRev: delta.rev,
                records: delta.records, sortKeyFor: sortKeyFor, now: now()
            )
        }
    }

    private func applyDeltaFrame(collection: String, rev: Int, records: [SyncWireRecord]) async throws {
        if builds[collection] != nil {
            // Mid-paging: queue, do not apply yet (DESIGN.md §3.4).
            builds[collection]?.queuedDeltas.append((rev: rev, records: records))
            return
        }
        try await store.applyDelta(
            teamID: teamID, collection: collection, frameRev: rev,
            records: records, sortKeyFor: sortKeyFor, now: now()
        )
    }
}
