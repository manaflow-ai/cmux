import Foundation

/// The changes one `apply(rows:)` tick made to a collection, shaped for direct
/// embedding in a `mobile.sync.delta` event. `nil` change means the tick was a
/// no-op and nothing travels.
public struct MobileSyncCollectionChange<Record: MobileSyncRecord>: Equatable, Sendable {
    public let fromRev: UInt64
    public let toRev: UInt64
    public let records: [Record]
    public let removedIDs: [String]
}

/// Mac-side versioned store for one synced collection.
///
/// The producer hands it the full current row set on every change tick; the
/// store diffs by record equality, stamps changed rows with a single new head
/// revision, records removals as bounded tombstones, and answers cursor
/// queries with a delta when the cursor is coverable and a snapshot otherwise.
/// Confined to the main actor because every producer input (TabManager,
/// notification store) and every consumer (RPC handlers) already lives there.
@MainActor
public final class MobileSyncCollectionStore<Record: MobileSyncRecord> {
    /// A record plus the head revision that last changed it.
    private struct Stamped {
        let record: Record
        let rev: UInt64
    }

    private struct Tombstone {
        let id: String
        let rev: UInt64
    }

    /// Upper bound on retained tombstones. A cursor older than the oldest
    /// retained removal cannot prove it missed no removal, so it gets a
    /// snapshot. 1024 removals between two client fetches is far past any real
    /// workspace-churn rate; the bound exists so memory never tracks history.
    private let maximumTombstoneCount: Int

    public private(set) var headRev: UInt64 = 0
    private var stampedByID: [String: Stamped] = [:]
    private var tombstones: [Tombstone] = []
    /// True once tombstones have been discarded to honor the bound; from then
    /// on only cursors at or above the oldest retained tombstone are coverable.
    private var droppedTombstones = false

    public init(maximumTombstoneCount: Int = 1024) {
        self.maximumTombstoneCount = maximumTombstoneCount
    }

    /// All current records, unordered. Ordering is the client's job via
    /// `syncSortIndex`.
    public var records: [Record] {
        stampedByID.values.map(\.record)
    }

    /// Diffs `rows` against the stored state. Changed and new rows are stamped
    /// with one new head revision; rows absent from `rows` become tombstones at
    /// that same revision. Returns `nil` when nothing changed (head unmoved).
    public func apply(rows: [Record]) -> MobileSyncCollectionChange<Record>? {
        var changed: [Record] = []
        var seenIDs = Set<String>()
        seenIDs.reserveCapacity(rows.count)
        for row in rows {
            guard seenIDs.insert(row.syncID).inserted else { continue }
            if stampedByID[row.syncID]?.record != row {
                changed.append(row)
            }
        }
        let removedIDs = stampedByID.keys.filter { !seenIDs.contains($0) }
        guard !changed.isEmpty || !removedIDs.isEmpty else { return nil }

        let fromRev = headRev
        headRev += 1
        for row in changed {
            stampedByID[row.syncID] = Stamped(record: row, rev: headRev)
        }
        for id in removedIDs {
            stampedByID[id] = nil
            tombstones.append(Tombstone(id: id, rev: headRev))
        }
        if tombstones.count > maximumTombstoneCount {
            tombstones.removeFirst(tombstones.count - maximumTombstoneCount)
            droppedTombstones = true
        }
        return MobileSyncCollectionChange(
            fromRev: fromRev,
            toRev: headRev,
            records: changed,
            removedIDs: removedIDs
        )
    }

    /// Whether a delta from `rev` can prove completeness. Coverable means every
    /// removal after `rev` is still retained; otherwise the client must
    /// snapshot. Upserts are always coverable because records store their full
    /// current row.
    private func canCover(rev: UInt64) -> Bool {
        guard rev <= headRev else { return false }
        guard droppedTombstones else { return true }
        guard let oldestRetained = tombstones.first?.rev else {
            // All tombstones were discarded; only a fully current cursor needs
            // no removal history.
            return rev == headRev
        }
        // A cursor at `rev` needs every removal with rev > `rev`. Retained
        // tombstones start at `oldestRetained`, so anything at or after
        // `oldestRetained - 1` is provably complete.
        return rev >= oldestRetained - 1
    }

    /// Answers one fetch section for a client at `cursor`. `nil` cursor, an
    /// epoch handled as mismatched by the caller, an uncoverable revision, or a
    /// future revision all resolve to a snapshot.
    public func payload(since rev: UInt64?) -> MobileSyncCollectionPayload<Record> {
        guard let rev, rev != headRev, canCover(rev: rev) else {
            if let rev, rev == headRev {
                return MobileSyncCollectionPayload(
                    mode: .delta,
                    rev: headRev,
                    fromRev: rev,
                    records: [],
                    removedIDs: []
                )
            }
            return MobileSyncCollectionPayload(
                mode: .snapshot,
                rev: headRev,
                fromRev: nil,
                records: records,
                removedIDs: []
            )
        }
        let upserts = stampedByID.values.filter { $0.rev > rev }.map(\.record)
        // A tombstone whose id is live again (removed then re-added inside the
        // cursor span) must not travel: the upsert alone is the correct final
        // state, and a client applying upserts and removals from one payload
        // would otherwise delete the re-added record.
        let removals = tombstones
            .filter { $0.rev > rev && stampedByID[$0.id] == nil }
            .map(\.id)
        return MobileSyncCollectionPayload(
            mode: .delta,
            rev: headRev,
            fromRev: rev,
            records: upserts,
            removedIDs: removals
        )
    }
}

/// The Mac's root sync store: one epoch spanning every collection, plus the
/// per-collection stores. Created once per app launch; the fresh epoch is what
/// invalidates every client cursor from a previous run.
@MainActor
public final class MobileStateSyncStore {
    public let epoch: String
    public let workspaces: MobileSyncCollectionStore<WorkspaceSyncRecord>
    public let groups: MobileSyncCollectionStore<GroupSyncRecord>

    public init(epoch: String = UUID().uuidString) {
        self.epoch = epoch
        self.workspaces = MobileSyncCollectionStore()
        self.groups = MobileSyncCollectionStore()
    }

    /// Answers a full `mobile.sync.fetch` request. Cursor epochs that do not
    /// match the store's epoch are treated as absent, which resolves to
    /// snapshots.
    public func fetchResponse(for request: MobileSyncFetchRequest) -> MobileSyncFetchResponse {
        var workspacesPayload: MobileSyncCollectionPayload<WorkspaceSyncRecord>?
        var groupsPayload: MobileSyncCollectionPayload<GroupSyncRecord>?
        for collection in request.collections {
            let rev = collection.epoch == epoch ? collection.rev : nil
            switch collection.id {
            case .workspaces:
                workspacesPayload = workspaces.payload(since: rev)
            case .groups:
                groupsPayload = groups.payload(since: rev)
            default:
                continue
            }
        }
        return MobileSyncFetchResponse(
            epoch: epoch,
            workspaces: workspacesPayload,
            groups: groupsPayload
        )
    }
}
