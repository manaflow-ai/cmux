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
    private let maxBufferedRecords: Int
    private let maxQueuedDeltaRecords: Int
    private let maxQueuedDeltaFrames: Int
    /// The collections this applier will accept frames for. A frame for any other
    /// collection is rejected as `.malformed` (forces a resync) so a misbehaving
    /// endpoint cannot stream incomplete snapshots / deltas for an unbounded set
    /// of unrequested collection names — each just under the per-collection
    /// ceiling — and grow `builds` (and create local cursor state) without a
    /// global bound. Empty = accept any collection (kept for tests/back-compat);
    /// production wiring passes the subscribed set.
    private let allowedCollections: Set<String>

    /// Per-collection in-flight snapshot: accumulated pages + the deltas that
    /// arrived during paging (queued, applied after the snapshot commits).
    private struct SnapshotBuild {
        var snapshotRev: Int
        var epoch: Int
        var records: [SyncWireRecord] = []
        var queuedDeltas: [(rev: Int, records: [SyncWireRecord])] = []
    }
    private var builds: [String: SnapshotBuild] = [:]

    /// Default ceiling on records accumulated across snapshot pages before a
    /// `complete` page arrives. The collection's record set is bounded server-side
    /// (presence caps: 200 devices × 25 instances), so any value far above the
    /// real cardinality only exists to stop a compromised/misbehaving DO from
    /// streaming an endless run of `complete: false` pages (or flooding deltas
    /// mid-paging) and driving unbounded client memory growth before any commit.
    public static let defaultMaxBufferedRecords = 100_000
    /// Default ceiling on total records retained across deltas queued while a
    /// snapshot is still paging (bounds memory by records, not frame count).
    /// Intentionally an order of magnitude TIGHTER than `defaultMaxBufferedRecords`:
    /// deltas queued during paging are transient overhead the completing snapshot
    /// will subsume, so the legitimate count is tiny (the devices collection is
    /// presence-capped well under 10k) and a stalled-snapshot producer should be
    /// cut off sooner here than on the snapshot pages themselves.
    public static let defaultMaxQueuedDeltaRecords = 10_000
    /// Default ceiling on the NUMBER of delta frames queued while a snapshot is
    /// paging, independent of how many records each carries. Without this a
    /// producer could hold a snapshot open and flood empty (`records: []`) deltas
    /// forever: each grows `queuedDeltas` by one entry while contributing 0 to the
    /// record bound, an unbounded-memory bypass. Both bounds are enforced.
    public static let defaultMaxQueuedDeltaFrames = 10_000

    public init(
        store: any CmuxSyncStoring,
        teamID: String,
        sortKeyFor: @escaping @Sendable (SyncWireRecord) -> Double,
        now: @escaping @Sendable () -> Date = { Date() },
        allowedCollections: Set<String> = [],
        maxBufferedRecords: Int = SyncFrameApplier.defaultMaxBufferedRecords,
        maxQueuedDeltaRecords: Int = SyncFrameApplier.defaultMaxQueuedDeltaRecords,
        maxQueuedDeltaFrames: Int = SyncFrameApplier.defaultMaxQueuedDeltaFrames
    ) {
        self.store = store
        self.teamID = teamID
        self.sortKeyFor = sortKeyFor
        self.now = now
        self.allowedCollections = allowedCollections
        self.maxBufferedRecords = maxBufferedRecords
        self.maxQueuedDeltaRecords = maxQueuedDeltaRecords
        self.maxQueuedDeltaFrames = maxQueuedDeltaFrames
    }

    /// Reject a frame for a collection this applier was not configured to accept.
    /// Throwing `.malformed` routes through `SyncClient`'s reset+rethrow so the
    /// in-flight buffers are cleared and the connection re-hellos.
    private func requireAllowed(_ collection: String) throws {
        if !allowedCollections.isEmpty, !allowedCollections.contains(collection) {
            throw SyncFrameParseError.malformed("frame for unrequested collection \(collection)")
        }
    }

    /// The cursor to send in the next `sync.hello` for a collection.
    public func cursor(collection: String) async throws -> Int {
        try await store.cursor(teamID: teamID, collection: collection)
    }

    /// The history epoch to send in the next `sync.hello` for a collection, so
    /// the server can detect a reset even at an equal head (DESIGN.md §3.6).
    public func epoch(collection: String) async throws -> Int {
        try await store.epoch(teamID: teamID, collection: collection)
    }

    /// Apply one server frame. Snapshot pages buffer until `complete`; deltas
    /// received mid-paging are queued and drained after the snapshot commits;
    /// deltas/ticks outside paging apply immediately. `.unknown` (a presence
    /// frame) is ignored.
    ///
    /// Returns whether a sync commit actually happened (the store was written or
    /// the cursor advanced). An `.unknown` presence frame, an incomplete snapshot
    /// page (buffered only), and a delta queued during paging return `false`, so
    /// the caller's `onApplied` UI invalidation does NOT fire on high-frequency
    /// presence traffic or partial pages.
    @discardableResult
    public func apply(_ frame: SyncServerFrame) async throws -> Bool {
        switch frame {
        case let .snapshot(collection, snapshotRev, epoch, records, complete):
            try requireAllowed(collection)
            return try await applySnapshotPage(collection: collection, snapshotRev: snapshotRev, epoch: epoch, records: records, complete: complete)
        case let .delta(collection, rev, records):
            try requireAllowed(collection)
            return try await applyDeltaFrame(collection: collection, rev: rev, records: records)
        case let .tick(collection, rev):
            try requireAllowed(collection)
            // A tick advances the cursor when nothing record-shaped changed. Safe
            // because the DO guarantees it has sent every record up to head
            // (DESIGN.md §3.2). During paging, a tick is ignored (the snapshot
            // commit sets the cursor); otherwise apply as an empty delta.
            if builds[collection] == nil {
                try await store.applyDelta(
                    teamID: teamID, collection: collection, frameRev: rev,
                    records: [], sortKeyFor: sortKeyFor, now: now()
                )
                return true
            }
            return false
        case .unknown:
            return false // presence frame or future type; not ours
        }
    }

    /// Discard any in-flight snapshot build for a collection on a stream drop, so
    /// a half-applied snapshot never commits; the reconnect re-hellos and gets a
    /// fresh snapshot (DESIGN.md §3.4).
    public func resetInFlight() {
        builds.removeAll()
    }

    /// Returns true once the snapshot's `complete` page commits; an incomplete
    /// page only buffers and returns false.
    private func applySnapshotPage(collection: String, snapshotRev: Int, epoch: Int, records: [SyncWireRecord], complete: Bool) async throws -> Bool {
        var build = builds[collection] ?? SnapshotBuild(snapshotRev: snapshotRev, epoch: epoch)
        // A snapshotRev or epoch change mid-paging means the server restarted the
        // snapshot (possibly into a new history); discard the stale buffer.
        if build.snapshotRev != snapshotRev || build.epoch != epoch {
            build = SnapshotBuild(snapshotRev: snapshotRev, epoch: epoch)
        }
        // Bound the buffer before appending: a malicious/compromised DO must not
        // be able to drive unbounded client memory by streaming an endless run of
        // `complete: false` pages. Drop the in-flight build and surface a malformed
        // frame so the transport tears down and re-hellos (the same recovery path
        // as any other structurally broken frame). Counted as pages-so-far + this
        // page so the ceiling holds even on a single oversized page.
        if build.records.count + records.count > maxBufferedRecords {
            builds[collection] = nil
            throw SyncFrameParseError.malformed(
                "snapshot for \(collection) exceeded \(maxBufferedRecords) buffered records before completing"
            )
        }
        build.records.append(contentsOf: records)
        if !complete {
            builds[collection] = build
            return false // buffered only, nothing committed yet
        }
        // Commit the full snapshot atomically (upserts + reconciliation + cursor +
        // epoch; reset-aware), then drain the deltas that raced the paging.
        try await store.applySnapshot(
            teamID: teamID, collection: collection, snapshotRev: snapshotRev, epoch: build.epoch,
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
        return true
    }

    /// Returns true when the delta is applied to the store; false when it is
    /// queued during paging (committed later when the snapshot completes).
    private func applyDeltaFrame(collection: String, rev: Int, records: [SyncWireRecord]) async throws -> Bool {
        if builds[collection] != nil {
            // Mid-paging: queue, do not apply yet (DESIGN.md §3.4). Bound the queue
            // on TWO independent axes so a producer that stalls a never-completing
            // snapshot cannot grow client memory without limit:
            //   1. total retained RECORDS — stops a single oversized multi-record
            //      delta (or many large ones) from blowing past the ceiling that a
            //      frame count alone would miss;
            //   2. total FRAMES — stops a flood of empty (`records: []`) deltas,
            //      each of which grows the queue by one entry while contributing 0
            //      to the record bound (the record-only bound would never trip).
            // On either overflow, drop the build and resync.
            let queuedFrames = builds[collection]?.queuedDeltas.count ?? 0
            let queuedRecords = builds[collection]?.queuedDeltas.reduce(0) { $0 + $1.records.count } ?? 0
            if queuedFrames + 1 > maxQueuedDeltaFrames || queuedRecords + records.count > maxQueuedDeltaRecords {
                builds[collection] = nil
                throw SyncFrameParseError.malformed(
                    "queued deltas for \(collection) exceeded the queue bound (frames \(maxQueuedDeltaFrames), records \(maxQueuedDeltaRecords)) while snapshot never completed"
                )
            }
            builds[collection]?.queuedDeltas.append((rev: rev, records: records))
            return false
        }
        try await store.applyDelta(
            teamID: teamID, collection: collection, frameRev: rev,
            records: records, sortKeyFor: sortKeyFor, now: now()
        )
        return true
    }
}
