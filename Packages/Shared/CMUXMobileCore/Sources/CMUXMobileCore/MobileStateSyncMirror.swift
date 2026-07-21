/// Outcome of applying a sync frame to a client mirror.
public enum MobileSyncApplyResult: Equatable, Sendable {
    /// The frame advanced (or re-covered) local state.
    case applied
    /// The frame ended at or before the local revision; nothing to do.
    case staleIgnored
    /// The frame starts past the local revision or belongs to another epoch;
    /// the caller must repair with a cursor fetch.
    case gap
}

/// Client-side mirror of one synced collection.
///
/// Holds full records keyed by id plus the cursor that proves how current they
/// are. Deltas apply iff contiguous-or-overlapping within the same epoch;
/// anything else reports `.gap` and leaves state untouched so the repair fetch
/// has a stable cursor to send. Main-actor confined to match its only
/// consumer, the shell state.
@MainActor
public final class MobileSyncCollectionMirror<Record: MobileSyncRecord> {
    public private(set) var epoch: String?
    public private(set) var rev: UInt64 = 0
    private var recordsByID: [String: Record] = [:]

    public init() {}

    /// Records in presentation order: `syncSortIndex`, then id for
    /// determinism when a delta lands between two rows' index updates.
    public var orderedRecords: [Record] {
        recordsByID.values.sorted {
            ($0.syncSortIndex, $0.syncID) < ($1.syncSortIndex, $1.syncID)
        }
    }

    /// Whether the mirror has adopted any state for `epoch` yet.
    public var hasState: Bool { epoch != nil }

    /// The cursor to present in a `mobile.sync.fetch`, once state exists.
    public var cursor: MobileSyncCursor? {
        guard let epoch else { return nil }
        return MobileSyncCursor(epoch: epoch, rev: rev)
    }

    /// Applies one fetch response section. Snapshots replace state
    /// unconditionally; deltas follow the same contiguity rule as events.
    public func apply(payload: MobileSyncCollectionPayload<Record>, epoch payloadEpoch: String) -> MobileSyncApplyResult {
        switch payload.mode {
        case .snapshot:
            // A same-epoch snapshot older than the cursor is a stale in-flight
            // response overtaken by newer deltas; applying it would roll the
            // mirror back until the next delta gaps and repairs. Ignore it.
            if let epoch, epoch == payloadEpoch, payload.rev < rev {
                return .staleIgnored
            }
            recordsByID = Dictionary(
                payload.records.map { ($0.syncID, $0) },
                uniquingKeysWith: { _, last in last }
            )
            epoch = payloadEpoch
            rev = payload.rev
            return .applied
        case .delta:
            return applyChanges(
                epoch: payloadEpoch,
                fromRev: payload.fromRev ?? payload.rev,
                toRev: payload.rev,
                records: payload.records,
                removedIDs: payload.removedIDs
            )
        }
    }

    /// Applies one `mobile.sync.delta` event.
    public func apply(delta: MobileSyncDeltaEvent<Record>) -> MobileSyncApplyResult {
        applyChanges(
            epoch: delta.epoch,
            fromRev: delta.fromRev,
            toRev: delta.toRev,
            records: delta.records,
            removedIDs: delta.removedIDs
        )
    }

    private func applyChanges(
        epoch changeEpoch: String,
        fromRev: UInt64,
        toRev: UInt64,
        records: [Record],
        removedIDs: [String]
    ) -> MobileSyncApplyResult {
        guard let epoch, epoch == changeEpoch else { return .gap }
        guard fromRev <= rev else { return .gap }
        guard toRev > rev else { return .staleIgnored }
        // Removals first: the producer already excludes tombstones for
        // currently-live ids, so within one payload an id in both lists means
        // the upsert is the newer fact and must win.
        for id in removedIDs {
            recordsByID[id] = nil
        }
        for record in records {
            recordsByID[record.syncID] = record
        }
        rev = toRev
        return .applied
    }

    /// Drops all state (disconnect-forget, sign-out, Mac unpair). The next
    /// fetch is a cold start.
    public func reset() {
        epoch = nil
        rev = 0
        recordsByID = [:]
    }
}

/// Client-side root mirror pairing the two synced collections, with the
/// cursor plumbing a `mobile.sync.fetch` round-trip needs.
@MainActor
public final class MobileStateSyncMirror {
    public let workspaces = MobileSyncCollectionMirror<WorkspaceSyncRecord>()
    public let groups = MobileSyncCollectionMirror<GroupSyncRecord>()

    public init() {}

    /// The fetch request that brings both collections current from their
    /// respective cursors (snapshots on cold start).
    public var fetchRequest: MobileSyncFetchRequest {
        MobileSyncFetchRequest(collections: [
            MobileSyncFetchRequest.Collection(
                id: .workspaces,
                epoch: workspaces.cursor?.epoch,
                rev: workspaces.cursor?.rev
            ),
            MobileSyncFetchRequest.Collection(
                id: .groups,
                epoch: groups.cursor?.epoch,
                rev: groups.cursor?.rev
            ),
        ])
    }

    /// Applies a fetch response to both collections. Returns `.gap` if either
    /// section gapped (caller re-fetches), `.applied` if anything advanced.
    public func apply(response: MobileSyncFetchResponse) -> MobileSyncApplyResult {
        var results: [MobileSyncApplyResult] = []
        if let payload = response.workspaces {
            results.append(workspaces.apply(payload: payload, epoch: response.epoch))
        }
        if let payload = response.groups {
            results.append(groups.apply(payload: payload, epoch: response.epoch))
        }
        if results.contains(.gap) { return .gap }
        if results.contains(.applied) { return .applied }
        return .staleIgnored
    }

    public func reset() {
        workspaces.reset()
        groups.reset()
    }
}
