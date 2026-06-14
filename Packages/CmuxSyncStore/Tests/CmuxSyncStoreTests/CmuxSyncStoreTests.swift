import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxSyncStore

private let TEAM = "team-1"
private let COLL = devicesSyncCollection
private let T0_MS = 1_750_000_000_000.0

private func makeStore() throws -> (CmuxSyncStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try CmuxSyncStore(databaseURL: dir.appendingPathComponent("cmux-sync.sqlite3"))
    return (store, dir)
}

/// Build a wire record carrying a `SyncedDeviceRecord` payload.
private func deviceRecord(
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

private let sortKey: @Sendable (SyncWireRecord) -> Double = { DeviceSyncFacade.sortKey(for: $0) }

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
        try await store.applySnapshot(teamID: TEAM, collection: COLL, snapshotRev: 3, records: [
            try deviceRecord(id: "dev-A", rev: 3),
        ], sortKeyFor: sortKey, now: Date())
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        #expect(live.map(\.recordID) == ["dev-A"]) // B dropped by reconciliation
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 3)
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
        try await store.applySnapshot(teamID: TEAM, collection: COLL, snapshotRev: 1, records: [
            try deviceRecord(id: "dev-A", rev: 1),
        ], sortKeyFor: sortKey, now: Date())
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        // The provisional row SURVIVES (rev >= 1 reconciliation exempts rev 0).
        #expect(Set(live.map(\.recordID)) == ["prov", "dev-A"])
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

@Suite struct SyncFrameApplierTests {
    @Test func snapshotPagesCommitOnlyOnComplete() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let applier = SyncFrameApplier(store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() })
        // First (incomplete) page: nothing should be committed yet.
        try await applier.apply(.snapshot(collection: COLL, snapshotRev: 2, records: [try deviceRecord(id: "dev-A", rev: 1)], complete: false))
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).isEmpty)
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 0)
        // Final page completes the snapshot: both records land, cursor commits.
        try await applier.apply(.snapshot(collection: COLL, snapshotRev: 2, records: [try deviceRecord(id: "dev-B", rev: 2)], complete: true))
        #expect(Set(try await store.liveRecords(teamID: TEAM, collection: COLL).map(\.recordID)) == ["dev-A", "dev-B"])
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 2)
    }

    @Test func deleteRacingSnapshotDuringPagingIsAppliedAfterCommit() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let applier = SyncFrameApplier(store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() })
        // Snapshot paging begins (head captured at 2): page 1 has A and B, not complete.
        try await applier.apply(.snapshot(collection: COLL, snapshotRev: 2, records: [
            try deviceRecord(id: "dev-A", rev: 1), try deviceRecord(id: "dev-B", rev: 2),
        ], complete: false))
        // B is deleted MID-PAGING => a delta at rev 3 arrives. It must be queued,
        // not dropped, and not applied yet.
        try await applier.apply(.delta(collection: COLL, rev: 3, records: [try deviceRecord(id: "dev-B", rev: 3, deleted: true)]))
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).isEmpty) // nothing committed yet
        // Snapshot completes => commit, then drain the queued delete. B must be gone.
        try await applier.apply(.snapshot(collection: COLL, snapshotRev: 2, records: [], complete: true))
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        #expect(live.map(\.recordID) == ["dev-A"]) // B removed by the queued tombstone, no ghost
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 3)
    }

    @Test func deltaOutsidePagingAppliesImmediately() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let applier = SyncFrameApplier(store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() })
        try await applier.apply(.delta(collection: COLL, rev: 1, records: [try deviceRecord(id: "dev-A", rev: 1)]))
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).count == 1)
    }

    @Test func tickAdvancesCursorWhenIdle() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let applier = SyncFrameApplier(store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() })
        try await applier.apply(.delta(collection: COLL, rev: 1, records: [try deviceRecord(id: "dev-A", rev: 1)]))
        try await applier.apply(.tick(collection: COLL, rev: 5))
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 5)
    }

    @Test func unknownFrameIsIgnored() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let applier = SyncFrameApplier(store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() })
        try await applier.apply(.unknown) // a presence frame on the shared socket
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 0)
    }

    @Test func applyReportsCommitOnlyOnActualWrite() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let applier = SyncFrameApplier(store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() })
        // Presence noise commits nothing.
        #expect(try await applier.apply(.unknown) == false)
        // An incomplete snapshot page buffers only — no commit.
        #expect(try await applier.apply(.snapshot(collection: COLL, snapshotRev: 2, records: [try deviceRecord(id: "dev-A", rev: 1)], complete: false)) == false)
        // A delta mid-paging is queued — no commit.
        #expect(try await applier.apply(.delta(collection: COLL, rev: 3, records: [try deviceRecord(id: "dev-B", rev: 3)])) == false)
        // The completing page commits => true.
        #expect(try await applier.apply(.snapshot(collection: COLL, snapshotRev: 2, records: [], complete: true)) == true)
        // A normal delta commits => true.
        #expect(try await applier.apply(.delta(collection: COLL, rev: 4, records: [try deviceRecord(id: "dev-C", rev: 4)])) == true)
        // An idle tick commits (advances cursor) => true.
        #expect(try await applier.apply(.tick(collection: COLL, rev: 9)) == true)
    }
}

@Suite struct LocalFirstRenderTests {
    @Test func facadeRendersDecodedDevicesFromStoreWithNoNetwork() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 1,
            records: [try deviceRecord(id: "dev-A", rev: 1, displayName: "Studio")],
            sortKeyFor: sortKey, now: Date())
        let facade = DeviceSyncFacade(store: store)
        let devices = try await facade.devices(teamID: TEAM)
        #expect(devices.count == 1)
        #expect(devices.first?.displayName == "Studio")
    }

    @Test func facadeMapsToRegistryDeviceShape() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 1,
            records: [try deviceRecord(id: "dev-A", rev: 1, displayName: "Studio", lastSeenMs: T0_MS)],
            sortKeyFor: sortKey, now: Date())
        let registry = try await DeviceSyncFacade(store: store).registryDevices(teamID: TEAM)
        #expect(registry.count == 1)
        let device = try #require(registry.first)
        #expect(device.deviceId == "dev-A")
        #expect(device.displayName == "Studio")
        // epoch ms in the record maps to a Date (ms / 1000).
        #expect(abs(device.lastSeenAt.timeIntervalSince1970 - T0_MS / 1000.0) < 0.001)
        #expect(device.instances.first?.tag == "default")
    }

    @Test func facadeKeepsDeviceWhenOneRouteIsMalformed() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Build a valid route in Swift (so the wire shape is correct), then inject
        // a malformed route object alongside it in the JSON payload. The whole
        // device must still render with just the valid route.
        let goodRoute = try CmxAttachRoute(id: "r1", kind: .tailscale,
            endpoint: .hostPort(host: "1.2.3.4", port: 8080), priority: 0)
        let goodJSON = String(data: try JSONEncoder().encode(goodRoute), encoding: .utf8)!
        let payload = Data("""
        {"deviceId":"dev-A","platform":"mac","lastSeenAtAtRev":1750000000000,
         "instances":[{"tag":"default","lastSeenAtAtRev":1750000000000,"routes":[
            \(goodJSON),
            {"id":"r2","kind":"futurekind","endpoint":{"weird":true},"priority":1}
         ]}]}
        """.utf8)
        let wire = SyncWireRecord(id: "dev-A", rev: 1, updatedAt: T0_MS, deleted: false,
            schemaVersion: syncSchemaVersion, payloadJSON: payload)
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 1, records: [wire],
            sortKeyFor: sortKey, now: Date())
        let devices = try await DeviceSyncFacade(store: store).devices(teamID: TEAM)
        #expect(devices.count == 1) // device NOT dropped despite the bad route
        #expect(devices.first?.instances.first?.routes.count == 1) // only the valid one
        #expect(devices.first?.instances.first?.routes.first?.id == "r1")
    }

    @Test func facadeSkipsUndecodableRows() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A row whose payload is not a SyncedDeviceRecord (e.g. a future schema).
        let junk = SyncWireRecord(id: "junk", rev: 1, updatedAt: T0_MS, deleted: false,
            schemaVersion: syncSchemaVersion, payloadJSON: Data(#"{"unexpected":true}"#.utf8))
        try await store.applyDelta(teamID: TEAM, collection: COLL, frameRev: 2, records: [
            junk, try deviceRecord(id: "dev-A", rev: 2),
        ], sortKeyFor: sortKey, now: Date())
        let devices = try await DeviceSyncFacade(store: store).devices(teamID: TEAM)
        #expect(devices.map(\.deviceId) == ["dev-A"]) // junk dropped, not a crash
    }
}

@Suite struct FrameCodecTests {
    @Test func parsesSnapshotDeltaTick() throws {
        let snap = try SyncFrameCodec.parse(Data(#"{"type":"sync.snapshot","collection":"devices","snapshotRev":7,"records":[{"id":"a","rev":3,"updatedAt":1,"deleted":false,"payload":{"x":1}}],"complete":true}"#.utf8))
        #expect(snap == .snapshot(collection: "devices", snapshotRev: 7,
            records: [SyncWireRecord(id: "a", rev: 3, updatedAt: 1, deleted: false, schemaVersion: syncSchemaVersion, payloadJSON: Data(#"{"x":1}"#.utf8))],
            complete: true))

        if case let .delta(collection, rev, records) = try SyncFrameCodec.parse(Data(#"{"type":"sync.delta","collection":"devices","rev":9,"records":[]}"#.utf8)) {
            #expect(collection == "devices"); #expect(rev == 9); #expect(records.isEmpty)
        } else { Issue.record("expected delta") }

        #expect(try SyncFrameCodec.parse(Data(#"{"type":"sync.tick","collection":"devices","rev":9}"#.utf8)) == .tick(collection: "devices", rev: 9))
    }

    @Test func presenceFramesParseAsUnknown() throws {
        // A presence frame on the shared socket is not a sync frame.
        #expect(try SyncFrameCodec.parse(Data(#"{"type":"online","instance":{}}"#.utf8)) == .unknown)
        #expect(try SyncFrameCodec.parse(Data(#"{"type":"snapshot","devices":[]}"#.utf8)) == .unknown)
    }

    @Test func nonJSONThrows() {
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec.parse(Data("not json".utf8))
        }
    }

    @Test func deltaOrSnapshotWithoutRecordsArrayThrows() {
        // A frame claiming to be sync but missing/wrong-typed `records` must
        // throw, so the client resyncs instead of committing an empty frame that
        // would silently advance the cursor / reconcile against nothing.
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec.parse(Data(#"{"type":"sync.delta","collection":"devices","rev":9}"#.utf8))
        }
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec.parse(Data(#"{"type":"sync.snapshot","collection":"devices","snapshotRev":9,"complete":true,"records":"oops"}"#.utf8))
        }
    }

    @Test func helloEncodesCollectionsAndCursors() throws {
        let data = try SyncFrameCodec.encodeHello(collections: [("devices", 12)])
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["type"] as? String == "sync.hello")
        #expect(obj["protocol"] as? String == syncProtocolV1)
    }
}

@Suite struct FlagTests {
    @Test func envOverrideWins() {
        #expect(MobileDeviceListLocalFirst.isEnabled(environment: ["CMUX_MOBILE_DEVICE_LIST_LOCAL_FIRST": "1"], defaults: UserDefaults(suiteName: "flag-1")!, isDebugBuild: false))
        #expect(!MobileDeviceListLocalFirst.isEnabled(environment: ["CMUX_MOBILE_DEVICE_LIST_LOCAL_FIRST": "0"], defaults: UserDefaults(suiteName: "flag-2")!, isDebugBuild: true))
    }

    @Test func debugDefaultsOnReleaseDefaultsOff() {
        let suite = UserDefaults(suiteName: "flag-3")!
        suite.removePersistentDomain(forName: "flag-3")
        #expect(MobileDeviceListLocalFirst.isEnabled(environment: [:], defaults: suite, isDebugBuild: true))
        #expect(!MobileDeviceListLocalFirst.isEnabled(environment: [:], defaults: suite, isDebugBuild: false))
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
}

@Suite struct PairedMacMigrationTests {
    /// A minimal in-memory MobilePairedMacStoring double for the migration test.
    actor FakePairedStore: MobilePairedMacStoring {
        var macs: [MobilePairedMac]
        init(macs: [MobilePairedMac]) { self.macs = macs }
        func upsert(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], markActive: Bool, stackUserID: String?, now: Date) async throws {}
        func loadAll(stackUserID: String?) async throws -> [MobilePairedMac] {
            guard let stackUserID else { return macs }
            return macs.filter { $0.stackUserID == stackUserID }
        }
        func activeMac(stackUserID: String?) async throws -> MobilePairedMac? { nil }
        func setActive(macDeviceID: String) async throws {}
        func remove(macDeviceID: String) async throws {}
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
