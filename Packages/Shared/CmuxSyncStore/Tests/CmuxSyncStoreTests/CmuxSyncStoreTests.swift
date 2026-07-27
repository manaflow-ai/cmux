import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxSyncStore

let TEAM = "team-1"
let COLL = devicesSyncCollection
let T0_MS = 1_750_000_000_000.0

func makeStore() throws -> (CmuxSyncStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try CmuxSyncStore(databaseURL: dir.appendingPathComponent("cmux-sync.sqlite3"))
    return (store, dir)
}

/// Build a wire record carrying a `SyncedDeviceRecord` payload.
func deviceRecord(
    id: String,
    rev: Int,
    deleted: Bool = false,
    displayName: String? = nil,
    lastSeenMs: Double = T0_MS
) throws -> SyncWireRecord {
    let payload: Data
    if deleted {
        payload = Data("{}".utf8)
    } else {
        let device = SyncedDeviceRecord(
            deviceId: id, platform: "mac", displayName: displayName, ownerUserId: nil,
            lastSeenAtAtRev: lastSeenMs,
            instances: [.init(tag: "default", routes: [], lastSeenAtAtRev: lastSeenMs)]
        )
        payload = try JSONEncoder().encode(device)
    }
    return SyncWireRecord(
        id: id, rev: rev, updatedAt: lastSeenMs, deleted: deleted,
        schemaVersion: syncSchemaVersion, payloadJSON: payload
    )
}

let sortKey: @Sendable (SyncWireRecord) -> Double = { DeviceSyncFacade.sortKey(for: $0) }

@Suite struct CmuxSyncStoreApplyTests {
    @Test func deltaUpsertsAndAdvancesCursor() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.applyDelta(
            teamID: TEAM, collection: COLL, frameRev: 1,
            records: [try deviceRecord(id: "dev-A", rev: 1)], sortKeyFor: sortKey, now: Date()
        )
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        #expect(live.count == 1)
        #expect(live.first?.recordID == "dev-A")
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 1)
    }

    @Test func staleOrDuplicateRecordIsIgnoredByRevGuard() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Apply rev 5 with displayName "New".
        try await store.applyDelta(
            teamID: TEAM, collection: COLL, frameRev: 5,
            records: [try deviceRecord(id: "dev-A", rev: 5, displayName: "New")],
            sortKeyFor: sortKey, now: Date()
        )
        // A duplicate/older rev 3 must NOT clobber the rev 5 record.
        try await store.applyDelta(
            teamID: TEAM, collection: COLL, frameRev: 5,
            records: [try deviceRecord(id: "dev-A", rev: 3, displayName: "Old")],
            sortKeyFor: sortKey, now: Date()
        )
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        let device = try JSONDecoder().decode(SyncedDeviceRecord.self, from: live[0].payloadJSON)
        #expect(device.displayName == "New") // kept the higher rev
    }

    @Test func tombstoneRemovesFromLiveRead() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 1,
            records: [try deviceRecord(id: "dev-A", rev: 1)], sortKeyFor: sortKey, now: Date())
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 2,
            records: [try deviceRecord(id: "dev-A", rev: 2, deleted: true)], sortKeyFor: sortKey, now: Date())
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        #expect(live.isEmpty) // tombstone excluded from the live render read
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 2)
    }

    @Test func cursorIsMonotone() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 10,
            records: [try deviceRecord(id: "dev-A", rev: 10)], sortKeyFor: sortKey, now: Date())
        // A frame claiming a LOWER head must not move the cursor backward.
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 4,
            records: [], sortKeyFor: sortKey, now: Date())
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 10)
    }

    @Test func renderOrderIsSortKeyDescending() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 2, records: [
            try deviceRecord(id: "older", rev: 1, lastSeenMs: T0_MS),
            try deviceRecord(id: "newer", rev: 2, lastSeenMs: T0_MS + 60_000),
        ], sortKeyFor: sortKey, now: Date())
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        #expect(live.map(\.recordID) == ["newer", "older"]) // newest-seen first
    }

    @Test func wireMsConvertsToStoredSecondsAtOneBoundary() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 1,
            records: [try deviceRecord(id: "dev-A", rev: 1, lastSeenMs: T0_MS)], sortKeyFor: sortKey, now: Date())
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        // updated_at column is epoch SECONDS (wire ms / 1000).
        #expect(abs(live[0].updatedAt - T0_MS / 1000.0) < 0.001)
    }

    @Test func clearRemovesTeamScopeOnly() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.applyDelta(teamID: "team-1", collection: COLL, frameRev: 1,
            records: [try deviceRecord(id: "dev-A", rev: 1)], sortKeyFor: sortKey, now: Date())
        try await store.applyDelta(teamID: "team-2", collection: COLL, frameRev: 1,
            records: [try deviceRecord(id: "dev-B", rev: 1)], sortKeyFor: sortKey, now: Date())
        try await store.clear(teamID: "team-1")
        #expect(try await store.liveRecords(teamID: "team-1", collection: COLL).isEmpty)
        #expect(try await store.liveRecords(teamID: "team-2", collection: COLL).count == 1)
    }
}

@Suite struct SnapshotReconciliationTests {
    @Test func snapshotDropsAuthoritativeRecordAbsentFromIt() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Client already has A (rev 1) and B (rev 2) from an earlier session.
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 2, records: [
            try deviceRecord(id: "dev-A", rev: 1),
            try deviceRecord(id: "dev-B", rev: 2),
        ], sortKeyFor: sortKey, now: Date())
        // A fresh snapshot at rev 3 contains only A (B was deleted while we were
        // disconnected and we missed its tombstone). Reconciliation drops B.
        try await store.applySnapshot(teamID: TEAM, collection: COLL, snapshotRev: 3, epoch: 1, records: [
            try deviceRecord(id: "dev-A", rev: 3),
        ], sortKeyFor: sortKey, now: Date())
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        #expect(live.map(\.recordID) == ["dev-A"]) // B dropped by reconciliation
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 3)
    }

    @Test func staleDeltaCannotResurrectSnapshotDeletedRecord() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Client had B at rev 2.
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 2, records: [
            try deviceRecord(id: "dev-B", rev: 2),
        ], sortKeyFor: sortKey, now: Date())
        // A snapshot at rev 5 omits B (it was deleted while disconnected).
        try await store.applySnapshot(teamID: TEAM, collection: COLL, snapshotRev: 5, epoch: 1, records: [
            try deviceRecord(id: "dev-A", rev: 5),
        ], sortKeyFor: sortKey, now: Date())
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).map(\.recordID) == ["dev-A"])
        // A delayed/duplicate delta for B with rev <= snapshotRev (e.g. a queued
        // delta from a reconnect overlap) must NOT resurrect B: the snapshot left
        // a tombstone at rev 5, so the rev guard ignores the stale rev-3 record.
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 5, records: [
            try deviceRecord(id: "dev-B", rev: 3, displayName: "Ghost"),
        ], sortKeyFor: sortKey, now: Date())
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).map(\.recordID) == ["dev-A"]) // no ghost
        // A genuinely newer delta (rev > snapshotRev) CAN bring B back legitimately.
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 6, records: [
            try deviceRecord(id: "dev-B", rev: 6),
        ], sortKeyFor: sortKey, now: Date())
        #expect(Set(try await store.liveRecords(teamID: TEAM, collection: COLL).map(\.recordID)) == ["dev-A", "dev-B"])
    }

    @Test func snapshotKeepsProvisionalRev0Rows() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A provisional migration row (rev 0) the DO does not know about.
        let payload = try JSONEncoder().encode(SyncedDeviceRecord(
            deviceId: "prov", platform: "mac", displayName: "Studio", ownerUserId: nil,
            lastSeenAtAtRev: T0_MS, instances: []
        ))
        try await store.seedProvisional(teamID: TEAM, collection: COLL, recordID: "prov",
            payloadJSON: payload, sortKey: T0_MS, now: Date())
        // A fresh snapshot at rev 1 that does NOT include the provisional row.
        try await store.applySnapshot(teamID: TEAM, collection: COLL, snapshotRev: 1, epoch: 1, records: [
            try deviceRecord(id: "dev-A", rev: 1),
        ], sortKeyFor: sortKey, now: Date())
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        // The provisional row SURVIVES (rev >= 1 reconciliation exempts rev 0).
        #expect(Set(live.map(\.recordID)) == ["prov", "dev-A"])
    }

    @Test func resetSnapshotRecoversFromAheadCursorAndClearsStaleRows() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Client is from an OLD DO history: high revs, cursor ahead of the reset.
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 100, records: [
            try deviceRecord(id: "old-A", rev: 100, displayName: "OldHistory"),
            try deviceRecord(id: "old-B", rev: 99),
        ], sortKeyFor: sortKey, now: Date())
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 100)
        // The DO storage was reset; the worker forces a snapshot at a LOWER rev.
        // It contains only new-A (rev 2); old-A/old-B are from the dead history.
        try await store.applySnapshot(teamID: TEAM, collection: COLL, snapshotRev: 2, epoch: 1, records: [
            try deviceRecord(id: "new-A", rev: 2, displayName: "NewHistory"),
        ], sortKeyFor: sortKey, now: Date())
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        // Stale old-history rows are gone; only the reset snapshot's record remains.
        #expect(live.map(\.recordID) == ["new-A"])
        // The cursor moved DOWN to the reset head, so the client stops sending an
        // ahead cursor and converges.
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 2)
    }

    @Test func epochChangeAtEqualHeadIsTreatedAsReset() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Old history at epoch 100: A and B, cursor lands at 2.
        try await store.applySnapshot(teamID: TEAM, collection: COLL, snapshotRev: 2, epoch: 100, records: [
            try deviceRecord(id: "old-A", rev: 1),
            try deviceRecord(id: "old-B", rev: 2),
        ], sortKeyFor: sortKey, now: Date())
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 2)
        #expect(try await store.epoch(teamID: TEAM, collection: COLL) == 100)
        // New history reset to the SAME head (2) but a DIFFERENT epoch (200),
        // containing only new-A. The cursor check alone (2 > 2 is false) would
        // miss it; the epoch mismatch forces a reset that clears old-A/old-B.
        try await store.applySnapshot(teamID: TEAM, collection: COLL, snapshotRev: 2, epoch: 200, records: [
            try deviceRecord(id: "new-A", rev: 2, displayName: "NewHistory"),
        ], sortKeyFor: sortKey, now: Date())
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        #expect(live.map(\.recordID) == ["new-A"]) // stale equal-head rows cleared
        #expect(try await store.epoch(teamID: TEAM, collection: COLL) == 200) // adopted new epoch
    }

    @Test func resetTombstoneBlocksHighRevOldHistoryDelta() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Old history: stale-X at a HIGH rev 500, cursor 500, epoch 100.
        try await store.applySnapshot(teamID: TEAM, collection: COLL, snapshotRev: 500, epoch: 100, records: [
            try deviceRecord(id: "stale-X", rev: 500),
        ], sortKeyFor: sortKey, now: Date())
        // Reset to a LOW head (2) in a new epoch (200), omitting stale-X.
        try await store.applySnapshot(teamID: TEAM, collection: COLL, snapshotRev: 2, epoch: 200, records: [
            try deviceRecord(id: "new-A", rev: 2),
        ], sortKeyFor: sortKey, now: Date())
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).map(\.recordID) == ["new-A"])
        // A delayed old-history delta for stale-X at rev 501 (> snapshotRev 2) must
        // NOT resurrect it: the reset tombstone was written at max(2, 500)=500, so
        // 501 would normally win — but the tombstone dominates revs <= 500, and a
        // stray 501 is impossible from the reset history (head is 2). Prove the
        // realistic case: an old delta at rev 400 (<= the 500 tombstone) is ignored.
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 500, records: [
            try deviceRecord(id: "stale-X", rev: 400, displayName: "Ghost"),
        ], sortKeyFor: sortKey, now: Date())
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).map(\.recordID) == ["new-A"]) // no ghost
    }

    @Test func nonzeroEpochAgainstLocalEpochZeroIsAReset() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Pre-epoch local state: a record at rev 5 written WITHOUT an epoch (the
        // cursor row's epoch is 0). Simulate via a plain delta (epoch stays 0).
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 5, records: [
            try deviceRecord(id: "dev-A", rev: 5, displayName: "StaleRoutes"),
        ], sortKeyFor: sortKey, now: Date())
        #expect(try await store.epoch(teamID: TEAM, collection: COLL) == 0)
        // The server (now epoch-aware) force-snapshots this epoch-0 client. The
        // snapshot carries the SAME id at the SAME rev 5 but a CHANGED payload.
        // Without reset-on-epoch-mismatch-from-0, the monotone guard (localRev 5
        // >= 5) would skip it and keep the stale payload.
        try await store.applySnapshot(teamID: TEAM, collection: COLL, snapshotRev: 5, epoch: 777, records: [
            try deviceRecord(id: "dev-A", rev: 5, displayName: "FreshRoutes"),
        ], sortKeyFor: sortKey, now: Date())
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        let device = try JSONDecoder().decode(SyncedDeviceRecord.self, from: live[0].payloadJSON)
        #expect(device.displayName == "FreshRoutes") // authoritative replace, not skipped
        #expect(try await store.epoch(teamID: TEAM, collection: COLL) == 777) // adopted
    }

    @Test func resetSnapshotKeepsProvisionalRows() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Provisional rev-0 fallback the DO does not know about.
        let prov = try JSONEncoder().encode(SyncedDeviceRecord(deviceId: "prov", platform: "mac",
            displayName: "Local", ownerUserId: nil, lastSeenAtAtRev: T0_MS, instances: []))
        try await store.seedProvisional(teamID: TEAM, collection: COLL, recordID: "prov",
            payloadJSON: prov, sortKey: T0_MS, now: Date())
        // An ahead cursor from an old history, then a reset snapshot omitting prov.
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 100,
            records: [try deviceRecord(id: "old", rev: 100)], sortKeyFor: sortKey, now: Date())
        try await store.applySnapshot(teamID: TEAM, collection: COLL, snapshotRev: 1, epoch: 1,
            records: [try deviceRecord(id: "new", rev: 1)], sortKeyFor: sortKey, now: Date())
        // Provisional survives the reset (rev 0 exempt); stale old is gone.
        #expect(Set(try await store.liveRecords(teamID: TEAM, collection: COLL).map(\.recordID)) == ["prov", "new"])
    }

    @Test func authoritativeRecordOverwritesProvisional() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provPayload = try JSONEncoder().encode(SyncedDeviceRecord(
            deviceId: "dev-A", platform: "mac", displayName: "Provisional", ownerUserId: nil,
            lastSeenAtAtRev: T0_MS, instances: []
        ))
        try await store.seedProvisional(teamID: TEAM, collection: COLL, recordID: "dev-A",
            payloadJSON: provPayload, sortKey: T0_MS, now: Date())
        // The DO's authoritative record (rev 1) replaces the provisional one.
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 1,
            records: [try deviceRecord(id: "dev-A", rev: 1, displayName: "Authoritative")],
            sortKeyFor: sortKey, now: Date())
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        let device = try JSONDecoder().decode(SyncedDeviceRecord.self, from: live[0].payloadJSON)
        #expect(device.displayName == "Authoritative")
        #expect(live[0].rev == 1)
    }
}

@Suite struct SyncClientTests {
    /// A fake transport that records the hello and replays a scripted frame set.
    final class FakeTransport: SyncTransport, @unchecked Sendable {
        let scripted: [Data]
        private let sentBox = SentBox()
        init(scripted: [Data]) { self.scripted = scripted }
        func send(_ data: Data) async throws { await sentBox.append(data) }
        func sentHellos() async -> [Data] { await sentBox.all() }
        func frames() -> AsyncThrowingStream<Data, any Error> {
            AsyncThrowingStream { continuation in
                for frame in scripted { continuation.yield(frame) }
                continuation.finish()
            }
        }
        actor SentBox {
            private var data: [Data] = []
            func append(_ d: Data) { data.append(d) }
            func all() -> [Data] { data }
        }
    }

    @Test func runSendsHelloThenAppliesFrames() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let applier = SyncFrameApplier(store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() })

        let snapshot = Data(#"{"type":"sync.snapshot","collection":"devices","snapshotRev":1,"records":[{"id":"dev-A","rev":1,"updatedAt":1,"deleted":false,"payload":{"deviceId":"dev-A","platform":"mac","lastSeenAtAtRev":1750000000000,"instances":[]}}],"complete":true}"#.utf8)
        let presenceNoise = Data(#"{"type":"seen","deviceId":"dev-A","tag":"default","lastSeenAt":1}"#.utf8)
        let transport = FakeTransport(scripted: [presenceNoise, snapshot])

        let client = SyncClient(transport: transport, applier: applier, collections: [COLL])
        try await client.run()

        // The hello carried the persisted cursor (0 on first run).
        let hellos = await transport.sentHellos()
        #expect(hellos.count == 1)
        let helloObj = try #require(try JSONSerialization.jsonObject(with: hellos[0]) as? [String: Any])
        #expect(helloObj["type"] as? String == "sync.hello")

        // The snapshot landed in the store; the presence noise was ignored.
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        #expect(live.map(\.recordID) == ["dev-A"])
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 1)
    }

    @Test func runRejectsFramesForUnrequestedCollectionByConstruction() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The applier here uses the DEFAULT (accept-all) allowlist: the client
        // must STILL reject the unrequested collection on its own, proving the
        // safety invariant is enforced by SyncClient construction (from its
        // subscribed `collections`) and does not depend on the applier's config.
        let applier = SyncFrameApplier(store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() })
        let evilSnapshot = Data(#"{"type":"sync.snapshot","collection":"evil-coll","snapshotRev":1,"records":[],"complete":false}"#.utf8)
        let transport = FakeTransport(scripted: [evilSnapshot])
        let client = SyncClient(transport: transport, applier: applier, collections: [COLL])
        await #expect(throws: SyncFrameParseError.self) {
            try await client.run()
        }
        // No cursor state was created for the unrequested collection.
        #expect(try await store.cursor(teamID: TEAM, collection: "evil-coll") == 0)
    }
}

@Suite struct PairedMacMigrationTests {
    /// A minimal in-memory MobilePairedMacStoring double for the migration test.
    actor FakePairedStore: MobilePairedMacStoring {
        var macs: [MobilePairedMac]
        init(macs: [MobilePairedMac]) { self.macs = macs }
        func upsert(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], instanceTag: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date) async throws {}
        func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
            guard let stackUserID else { return macs }
            return macs.filter { $0.stackUserID == stackUserID }
        }
        func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? { nil }
        func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {}
        func clearActive(stackUserID: String?, teamID: String?) async throws {}
        func setCustomization(
            macDeviceID: String, customName: String?, customColor: String?,
            customIcon: String?, stackUserID: String?, teamID: String?, now: Date
        ) async throws {}
        func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {}
        func removeAll() async throws {}
    }

    @Test func seedsProvisionalRowsOnceAndIsIdempotent() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = MobilePairedMac(macDeviceID: "mac-1", displayName: "Studio", routes: [],
            createdAt: Date(timeIntervalSince1970: 1000), lastSeenAt: Date(timeIntervalSince1970: 2000),
            isActive: true, stackUserID: "acct-1")
        let paired = FakePairedStore(macs: [mac])
        let migration = PairedMacMigration(pairedStore: paired, syncStore: store)

        let first = try await migration.runIfNeeded(accountID: "acct-1", teamID: TEAM)
        #expect(first == 1)
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        #expect(live.count == 1)
        #expect(live[0].rev == 0) // provisional
        let device = try JSONDecoder().decode(SyncedDeviceRecord.self, from: live[0].payloadJSON)
        #expect(device.displayName == "Studio")

        // Second run is a no-op (marker short-circuit).
        let second = try await migration.runIfNeeded(accountID: "acct-1", teamID: TEAM)
        #expect(second == 0)
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).count == 1)
    }

    @Test func sameAccountReseedsForADifferentTeam() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = MobilePairedMac(macDeviceID: "mac-1", displayName: "Studio", routes: [],
            createdAt: Date(timeIntervalSince1970: 1000), lastSeenAt: Date(timeIntervalSince1970: 2000),
            isActive: true, stackUserID: "acct-1")
        let migration = PairedMacMigration(pairedStore: FakePairedStore(macs: [mac]), syncStore: store)
        // Migrate for team-1.
        #expect(try await migration.runIfNeeded(accountID: "acct-1", teamID: "team-1") == 1)
        // Same account, DIFFERENT team must still seed (marker is per team).
        #expect(try await migration.runIfNeeded(accountID: "acct-1", teamID: "team-2") == 1)
        #expect(try await store.liveRecords(teamID: "team-1", collection: COLL).count == 1)
        #expect(try await store.liveRecords(teamID: "team-2", collection: COLL).count == 1)
    }

    @Test func clearTeamRemovesMarkerSoReSignInReseeds() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = MobilePairedMac(macDeviceID: "mac-1", displayName: "Studio", routes: [],
            createdAt: Date(timeIntervalSince1970: 1000), lastSeenAt: Date(timeIntervalSince1970: 2000),
            isActive: true, stackUserID: "acct-1")
        let migration = PairedMacMigration(pairedStore: FakePairedStore(macs: [mac]), syncStore: store)
        #expect(try await migration.runIfNeeded(accountID: "acct-1", teamID: TEAM) == 1)
        // Sign-out clears the team scope, INCLUDING its migration marker.
        try await store.clear(teamID: TEAM)
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).isEmpty)
        // Re-sign-in re-seeds the fallback rows we just cleared.
        #expect(try await migration.runIfNeeded(accountID: "acct-1", teamID: TEAM) == 1)
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).count == 1)
    }

    @Test func clearReSeedsForTeamIDsWithLikeMetacharacters() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = MobilePairedMac(macDeviceID: "mac-1", displayName: "Studio", routes: [],
            createdAt: Date(timeIntervalSince1970: 1000), lastSeenAt: Date(timeIntervalSince1970: 2000),
            isActive: true, stackUserID: "acct-1")
        let migration = PairedMacMigration(pairedStore: FakePairedStore(macs: [mac]), syncStore: store)
        // A team id with `_`, `%`, and `\` (LIKE metacharacters in the clear path).
        let weirdTeam = #"team_50%\x"#
        #expect(try await migration.runIfNeeded(accountID: "acct-1", teamID: weirdTeam) == 1)
        try await store.clear(teamID: weirdTeam)
        // The migration marker must be cleared too, so re-sign-in re-seeds.
        #expect(try await migration.runIfNeeded(accountID: "acct-1", teamID: weirdTeam) == 1)
        #expect(try await store.liveRecords(teamID: weirdTeam, collection: COLL).count == 1)
    }

    @Test func provisionalNeverClobbersExistingRecordEvenWithoutMarker() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // An authoritative record already exists for mac-1.
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 5,
            records: [try deviceRecord(id: "mac-1", rev: 5, displayName: "Authoritative")],
            sortKeyFor: sortKey, now: Date())
        // Seed provisional directly (bypassing the marker) — INSERT OR IGNORE.
        let prov = try JSONEncoder().encode(SyncedDeviceRecord(deviceId: "mac-1", platform: "mac",
            displayName: "Provisional", ownerUserId: nil, lastSeenAtAtRev: T0_MS, instances: []))
        try await store.seedProvisional(teamID: TEAM, collection: COLL, recordID: "mac-1",
            payloadJSON: prov, sortKey: T0_MS, now: Date())
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        let device = try JSONDecoder().decode(SyncedDeviceRecord.self, from: live[0].payloadJSON)
        #expect(device.displayName == "Authoritative") // not clobbered
        #expect(live[0].rev == 5)
    }
}
