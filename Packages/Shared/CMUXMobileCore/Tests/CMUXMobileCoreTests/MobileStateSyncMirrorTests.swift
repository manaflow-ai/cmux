import Testing

@testable import CMUXMobileCore

@MainActor
struct MobileStateSyncMirrorTests {
    private func group(id: String, name: String = "g", sortIndex: Int = 0) -> GroupSyncRecord {
        GroupSyncRecord(
            id: id,
            name: name,
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceID: id + "-anchor",
            sortIndex: sortIndex
        )
    }

    private func snapshot(
        _ records: [GroupSyncRecord],
        rev: UInt64
    ) -> MobileSyncCollectionPayload<GroupSyncRecord> {
        MobileSyncCollectionPayload(
            mode: .snapshot,
            rev: rev,
            fromRev: nil,
            records: records,
            removedIDs: []
        )
    }

    private func delta(
        epoch: String,
        fromRev: UInt64,
        toRev: UInt64,
        records: [GroupSyncRecord] = [],
        removedIDs: [String] = []
    ) -> MobileSyncDeltaEvent<GroupSyncRecord> {
        MobileSyncDeltaEvent(
            epoch: epoch,
            collection: .groups,
            fromRev: fromRev,
            toRev: toRev,
            records: records,
            removedIDs: removedIDs
        )
    }

    @Test func snapshotReplacesStateAndAdoptsCursor() {
        let mirror = MobileSyncCollectionMirror<GroupSyncRecord>()
        #expect(mirror.cursor == nil)
        let result = mirror.apply(payload: snapshot([group(id: "a"), group(id: "b")], rev: 7), epoch: "e1")
        #expect(result == .applied)
        #expect(mirror.cursor == MobileSyncCursor(epoch: "e1", rev: 7))
        #expect(mirror.orderedRecords.map(\.syncID) == ["a", "b"])
    }

    @Test func contiguousDeltaAdvances() {
        let mirror = MobileSyncCollectionMirror<GroupSyncRecord>()
        _ = mirror.apply(payload: snapshot([group(id: "a")], rev: 1), epoch: "e1")
        let result = mirror.apply(delta: delta(epoch: "e1", fromRev: 1, toRev: 2, records: [group(id: "b")]))
        #expect(result == .applied)
        #expect(mirror.rev == 2)
        #expect(mirror.orderedRecords.map(\.syncID) == ["a", "b"])
    }

    @Test func overlappingDeltaAppliesIdempotently() {
        let mirror = MobileSyncCollectionMirror<GroupSyncRecord>()
        _ = mirror.apply(payload: snapshot([group(id: "a")], rev: 5), epoch: "e1")
        // A frame covering (3, 6] arrives after a snapshot at 5: overlap, safe.
        let result = mirror.apply(
            delta: delta(epoch: "e1", fromRev: 3, toRev: 6, records: [group(id: "a", name: "renamed")])
        )
        #expect(result == .applied)
        #expect(mirror.rev == 6)
        #expect(mirror.orderedRecords.first?.name == "renamed")
    }

    @Test func staleDeltaIsIgnoredWithoutStateChange() {
        let mirror = MobileSyncCollectionMirror<GroupSyncRecord>()
        _ = mirror.apply(payload: snapshot([group(id: "a")], rev: 5), epoch: "e1")
        let result = mirror.apply(
            delta: delta(epoch: "e1", fromRev: 2, toRev: 4, removedIDs: ["a"])
        )
        #expect(result == .staleIgnored)
        #expect(mirror.rev == 5)
        #expect(mirror.orderedRecords.count == 1)
    }

    @Test func gappedDeltaReportsGapAndLeavesStateUntouched() {
        let mirror = MobileSyncCollectionMirror<GroupSyncRecord>()
        _ = mirror.apply(payload: snapshot([group(id: "a")], rev: 5), epoch: "e1")
        let result = mirror.apply(delta: delta(epoch: "e1", fromRev: 7, toRev: 9, removedIDs: ["a"]))
        #expect(result == .gap)
        #expect(mirror.rev == 5)
        #expect(mirror.orderedRecords.count == 1)
    }

    @Test func staleSameEpochSnapshotIsIgnored() {
        let mirror = MobileSyncCollectionMirror<GroupSyncRecord>()
        _ = mirror.apply(payload: snapshot([group(id: "a"), group(id: "b")], rev: 8), epoch: "e1")
        // An in-flight fetch response from rev 5 lands after newer deltas
        // advanced the mirror to 8: applying it would roll state back until
        // the next delta gaps. It must be ignored.
        let result = mirror.apply(payload: snapshot([group(id: "a")], rev: 5), epoch: "e1")
        #expect(result == .staleIgnored)
        #expect(mirror.rev == 8)
        #expect(mirror.orderedRecords.count == 2)
        // A NEW epoch's snapshot always applies, whatever its revision.
        let newEpoch = mirror.apply(payload: snapshot([group(id: "c")], rev: 1), epoch: "e2")
        #expect(newEpoch == .applied)
        #expect(mirror.orderedRecords.map(\.syncID) == ["c"])
    }

    @Test func epochMismatchReportsGap() {
        let mirror = MobileSyncCollectionMirror<GroupSyncRecord>()
        _ = mirror.apply(payload: snapshot([group(id: "a")], rev: 5), epoch: "e1")
        #expect(mirror.apply(delta: delta(epoch: "e2", fromRev: 5, toRev: 6)) == .gap)
    }

    @Test func deltaBeforeAnyStateReportsGap() {
        let mirror = MobileSyncCollectionMirror<GroupSyncRecord>()
        #expect(mirror.apply(delta: delta(epoch: "e1", fromRev: 0, toRev: 1)) == .gap)
    }

    @Test func removalDropsRecord() {
        let mirror = MobileSyncCollectionMirror<GroupSyncRecord>()
        _ = mirror.apply(payload: snapshot([group(id: "a"), group(id: "b")], rev: 1), epoch: "e1")
        _ = mirror.apply(delta: delta(epoch: "e1", fromRev: 1, toRev: 2, removedIDs: ["a"]))
        #expect(mirror.orderedRecords.map(\.syncID) == ["b"])
    }

    @Test func orderingFollowsSortIndexThenID() {
        let mirror = MobileSyncCollectionMirror<GroupSyncRecord>()
        _ = mirror.apply(
            payload: snapshot(
                [group(id: "z", sortIndex: 0), group(id: "a", sortIndex: 1), group(id: "m", sortIndex: 0)],
                rev: 1
            ),
            epoch: "e1"
        )
        #expect(mirror.orderedRecords.map(\.syncID) == ["m", "z", "a"])
    }

    @Test func resetForgetsEverything() {
        let mirror = MobileSyncCollectionMirror<GroupSyncRecord>()
        _ = mirror.apply(payload: snapshot([group(id: "a")], rev: 5), epoch: "e1")
        mirror.reset()
        #expect(mirror.cursor == nil)
        #expect(mirror.orderedRecords.isEmpty)
        // After reset, a delta cannot apply until a snapshot re-establishes state.
        #expect(mirror.apply(delta: delta(epoch: "e1", fromRev: 5, toRev: 6)) == .gap)
    }

    @Test func rootMirrorRoundTripsWithRootStore() {
        let store = MobileStateSyncStore()
        _ = store.groups.apply(rows: [group(id: "g1")])
        let mirror = MobileStateSyncMirror()

        // Cold fetch: snapshot.
        let cold = store.fetchResponse(for: mirror.fetchRequest)
        #expect(cold.groups?.mode == .snapshot)
        #expect(mirror.apply(response: cold) == .applied)
        #expect(mirror.groups.orderedRecords.map(\.syncID) == ["g1"])

        // Change on the Mac, delta event to the phone.
        let change = store.groups.apply(rows: [group(id: "g1", name: "renamed"), group(id: "g2", sortIndex: 1)])
        let event = MobileSyncDeltaEvent(
            epoch: store.epoch,
            collection: .groups,
            fromRev: change?.fromRev ?? 0,
            toRev: change?.toRev ?? 0,
            records: change?.records ?? [],
            removedIDs: change?.removedIDs ?? []
        )
        #expect(mirror.groups.apply(delta: event) == .applied)
        #expect(mirror.groups.orderedRecords.map(\.name) == ["renamed", "g"])

        // Warm fetch after the event: empty delta, nothing to re-send.
        let warm = store.fetchResponse(for: mirror.fetchRequest)
        #expect(warm.groups?.mode == .delta)
        #expect(warm.groups?.records.isEmpty == true)
        #expect(mirror.apply(response: warm) == .staleIgnored)
    }
}
