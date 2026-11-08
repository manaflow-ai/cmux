import Testing

@testable import CMUXMobileCore

@MainActor
struct MobileStateSyncStoreTests {
    private func workspace(
        id: String,
        title: String = "ws",
        preview: String? = nil,
        hasUnread: Bool = false,
        sortIndex: Int = 0
    ) -> WorkspaceSyncRecord {
        WorkspaceSyncRecord(
            id: id,
            windowID: "w1",
            title: title,
            currentDirectory: "/tmp",
            isSelected: false,
            isPinned: false,
            groupID: nil,
            preview: preview,
            previewAt: preview == nil ? nil : 1.0,
            lastActivityAt: 1.0,
            hasUnread: hasUnread,
            sortIndex: sortIndex,
            terminals: [
                WorkspaceSyncRecord.Terminal(
                    id: id + "-t1",
                    title: "zsh",
                    currentDirectory: "/tmp",
                    isReady: true,
                    isFocused: true
                )
            ]
        )
    }

    @Test func firstApplyStampsEveryRowAtRevOne() {
        let store = MobileSyncCollectionStore<WorkspaceSyncRecord>()
        let change = store.apply(rows: [workspace(id: "a"), workspace(id: "b")])
        #expect(change?.fromRev == 0)
        #expect(change?.toRev == 1)
        #expect(change?.records.count == 2)
        #expect(change?.removedIDs.isEmpty == true)
        #expect(store.headRev == 1)
    }

    @Test func identicalApplyIsANoOpAndMovesNoRevision() {
        let store = MobileSyncCollectionStore<WorkspaceSyncRecord>()
        let rows = [workspace(id: "a"), workspace(id: "b")]
        _ = store.apply(rows: rows)
        #expect(store.apply(rows: rows) == nil)
        #expect(store.headRev == 1)
    }

    @Test func changedRowTravelsAloneInTheDelta() {
        let store = MobileSyncCollectionStore<WorkspaceSyncRecord>()
        _ = store.apply(rows: [workspace(id: "a"), workspace(id: "b")])
        let change = store.apply(rows: [
            workspace(id: "a", preview: "new output", hasUnread: true),
            workspace(id: "b"),
        ])
        #expect(change?.records.map(\.syncID) == ["a"])
        #expect(change?.fromRev == 1)
        #expect(change?.toRev == 2)
    }

    @Test func removalBecomesTombstoneAndDeltaCarriesIt() {
        let store = MobileSyncCollectionStore<WorkspaceSyncRecord>()
        _ = store.apply(rows: [workspace(id: "a"), workspace(id: "b")])
        let change = store.apply(rows: [workspace(id: "a")])
        #expect(change?.records.isEmpty == true)
        #expect(change?.removedIDs == ["b"])

        let payload = store.payload(since: 1)
        #expect(payload.mode == .delta)
        #expect(payload.removedIDs == ["b"])
        #expect(payload.records.isEmpty)
        #expect(payload.rev == 2)
    }

    @Test func duplicateIDsInOneApplyKeepTheFirstRow() {
        let store = MobileSyncCollectionStore<WorkspaceSyncRecord>()
        let change = store.apply(rows: [
            workspace(id: "a", title: "first"),
            workspace(id: "a", title: "second"),
        ])
        #expect(change?.records.map(\.title) == ["first"])
    }

    @Test func currentCursorGetsEmptyDelta() {
        let store = MobileSyncCollectionStore<WorkspaceSyncRecord>()
        _ = store.apply(rows: [workspace(id: "a")])
        let payload = store.payload(since: store.headRev)
        #expect(payload.mode == .delta)
        #expect(payload.records.isEmpty)
        #expect(payload.removedIDs.isEmpty)
        #expect(payload.fromRev == store.headRev)
        #expect(payload.rev == store.headRev)
    }

    @Test func coldCursorGetsSnapshot() {
        let store = MobileSyncCollectionStore<WorkspaceSyncRecord>()
        _ = store.apply(rows: [workspace(id: "a"), workspace(id: "b")])
        let payload = store.payload(since: nil)
        #expect(payload.mode == .snapshot)
        #expect(payload.records.count == 2)
        #expect(payload.fromRev == nil)
    }

    @Test func futureCursorGetsSnapshot() {
        let store = MobileSyncCollectionStore<WorkspaceSyncRecord>()
        _ = store.apply(rows: [workspace(id: "a")])
        #expect(store.payload(since: 99).mode == .snapshot)
    }

    @Test func deltaSpansMultipleTicks() {
        let store = MobileSyncCollectionStore<WorkspaceSyncRecord>()
        _ = store.apply(rows: [workspace(id: "a")])
        _ = store.apply(rows: [workspace(id: "a"), workspace(id: "b")])
        _ = store.apply(rows: [workspace(id: "b")])
        let payload = store.payload(since: 1)
        #expect(payload.mode == .delta)
        #expect(payload.records.map(\.syncID) == ["b"])
        #expect(payload.removedIDs == ["a"])
        #expect(payload.rev == 3)
    }

    @Test func cursorOlderThanRetainedTombstonesGetsSnapshot() {
        let store = MobileSyncCollectionStore<WorkspaceSyncRecord>(maximumTombstoneCount: 2)
        _ = store.apply(rows: [
            workspace(id: "a"), workspace(id: "b"),
            workspace(id: "c"), workspace(id: "d"),
        ])
        _ = store.apply(rows: [workspace(id: "b"), workspace(id: "c"), workspace(id: "d")])
        _ = store.apply(rows: [workspace(id: "c"), workspace(id: "d")])
        _ = store.apply(rows: [workspace(id: "d")])
        // Three removals happened (revs 2, 3, 4); the ring keeps two. A cursor
        // from rev 1 cannot prove it saw removal rev 2, so it must snapshot.
        #expect(store.payload(since: 1).mode == .snapshot)
        // A cursor at rev 2 needs removals 3 and 4, both retained: delta.
        let covered = store.payload(since: 2)
        #expect(covered.mode == .delta)
        #expect(Set(covered.removedIDs) == Set(["b", "c"]))
    }

    @Test func removedThenReaddedRecordTravelsAsUpsertWithoutTombstone() {
        let store = MobileSyncCollectionStore<WorkspaceSyncRecord>()
        _ = store.apply(rows: [workspace(id: "a"), workspace(id: "b")])
        _ = store.apply(rows: [workspace(id: "b")])
        _ = store.apply(rows: [workspace(id: "b"), workspace(id: "a", title: "reborn")])
        // A cursor from before the removal spans remove-then-readd. The
        // payload must deliver the live row and no tombstone for it; a client
        // applying both would delete the re-added record.
        let payload = store.payload(since: 1)
        #expect(payload.mode == .delta)
        #expect(payload.records.map(\.syncID) == ["a"])
        #expect(payload.records.first?.title == "reborn")
        #expect(payload.removedIDs.isEmpty)
    }

    @Test func splitTombstoneRevisionBatchForcesSnapshot() {
        let store = MobileSyncCollectionStore<WorkspaceSyncRecord>(maximumTombstoneCount: 2)
        _ = store.apply(rows: [
            workspace(id: "a"), workspace(id: "b"),
            workspace(id: "c"), workspace(id: "d"),
        ])
        // One tick removes three records, all tombstoned at rev 2; the ring
        // keeps only two of them. A cursor at rev 1 cannot prove it saw the
        // discarded rev-2 removal, so a delta would leave a ghost record —
        // it must snapshot even though retained tombstones start at rev 2.
        _ = store.apply(rows: [workspace(id: "d")])
        #expect(store.payload(since: 1).mode == .snapshot)
        // A cursor at the discarded bound itself is safe: every removal it
        // needs (rev > 2) is fully retained.
        _ = store.apply(rows: [])
        #expect(store.payload(since: 2).mode == .delta)
        #expect(store.payload(since: 2).removedIDs == ["d"])
    }

    @Test func rootStoreMismatchedEpochResolvesToSnapshot() {
        let store = MobileStateSyncStore(epoch: "epoch-1")
        _ = store.workspaces.apply(rows: [workspace(id: "a")])
        let response = store.fetchResponse(
            for: MobileSyncFetchRequest(collections: [
                MobileSyncFetchRequest.Collection(id: .workspaces, epoch: "epoch-0", rev: 1)
            ])
        )
        #expect(response.epoch == "epoch-1")
        #expect(response.workspaces?.mode == .snapshot)
        #expect(response.groups == nil)
    }

    @Test func rootStoreMatchingEpochResolvesToDelta() {
        let store = MobileStateSyncStore(epoch: "epoch-1")
        _ = store.workspaces.apply(rows: [workspace(id: "a")])
        _ = store.workspaces.apply(rows: [workspace(id: "a", hasUnread: true)])
        let response = store.fetchResponse(
            for: MobileSyncFetchRequest(collections: [
                MobileSyncFetchRequest.Collection(id: .workspaces, epoch: "epoch-1", rev: 1)
            ])
        )
        #expect(response.workspaces?.mode == .delta)
        #expect(response.workspaces?.records.map(\.syncID) == ["a"])
    }

    @Test func rootStoreIgnoresUnknownCollections() {
        let store = MobileStateSyncStore()
        let response = store.fetchResponse(
            for: MobileSyncFetchRequest(collections: [
                MobileSyncFetchRequest.Collection(
                    id: MobileSyncCollectionID(rawValue: "future_collection"),
                    epoch: nil,
                    rev: nil
                )
            ])
        )
        #expect(response.workspaces == nil)
        #expect(response.groups == nil)
    }
}
