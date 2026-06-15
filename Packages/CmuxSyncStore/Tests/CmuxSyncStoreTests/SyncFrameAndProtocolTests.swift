import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxSyncStore

// Sync apply/transport/codec/flag/migration suites. Shared helpers (TEAM, COLL,
// makeStore, deviceRecord, sortKey) live in CmuxSyncStoreTests.swift.

@Suite struct SyncFrameApplierTests {
    @Test func snapshotPagesCommitOnlyOnComplete() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let applier = SyncFrameApplier(store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() })
        // First (incomplete) page: nothing should be committed yet.
        try await applier.apply(.snapshot(collection: COLL, snapshotRev: 2, epoch: 1, records: [try deviceRecord(id: "dev-A", rev: 1)], complete: false))
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).isEmpty)
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 0)
        // Final page completes the snapshot: both records land, cursor commits.
        try await applier.apply(.snapshot(collection: COLL, snapshotRev: 2, epoch: 1, records: [try deviceRecord(id: "dev-B", rev: 2)], complete: true))
        #expect(Set(try await store.liveRecords(teamID: TEAM, collection: COLL).map(\.recordID)) == ["dev-A", "dev-B"])
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 2)
    }

    @Test func deleteRacingSnapshotDuringPagingIsAppliedAfterCommit() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let applier = SyncFrameApplier(store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() })
        // Snapshot paging begins (head captured at 2): page 1 has A and B, not complete.
        try await applier.apply(.snapshot(collection: COLL, snapshotRev: 2, epoch: 1, records: [
            try deviceRecord(id: "dev-A", rev: 1), try deviceRecord(id: "dev-B", rev: 2),
        ], complete: false))
        // B is deleted MID-PAGING => a delta at rev 3 arrives. It must be queued,
        // not dropped, and not applied yet.
        try await applier.apply(.delta(collection: COLL, rev: 3, records: [try deviceRecord(id: "dev-B", rev: 3, deleted: true)]))
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).isEmpty) // nothing committed yet
        // Snapshot completes => commit, then drain the queued delete. B must be gone.
        try await applier.apply(.snapshot(collection: COLL, snapshotRev: 2, epoch: 1, records: [], complete: true))
        let live = try await store.liveRecords(teamID: TEAM, collection: COLL)
        #expect(live.map(\.recordID) == ["dev-A"]) // B removed by the queued tombstone, no ghost
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 3)
    }

    @Test func snapshotPagingBufferIsBoundedAgainstEndlessIncompletePages() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Tiny ceiling so a compromised/misbehaving DO that streams an endless run
        // of `complete: false` pages cannot grow client memory without limit: the
        // applier must drop the in-flight build and surface a malformed frame so
        // the transport tears down + re-hellos.
        let applier = SyncFrameApplier(
            store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() },
            maxBufferedRecords: 2
        )
        try await applier.apply(.snapshot(collection: COLL, snapshotRev: 9, epoch: 1, records: [
            try deviceRecord(id: "dev-A", rev: 1), try deviceRecord(id: "dev-B", rev: 2),
        ], complete: false))
        await #expect(throws: SyncFrameParseError.self) {
            try await applier.apply(.snapshot(collection: COLL, snapshotRev: 9, epoch: 1, records: [
                try deviceRecord(id: "dev-C", rev: 3),
            ], complete: false))
        }
        // Build was dropped on overflow: nothing committed, cursor never advanced,
        // so a fresh re-hello gets a clean snapshot.
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).isEmpty)
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 0)
    }

    @Test func queuedDeltaBufferIsBoundedByRetainedRecordsWhenSnapshotNeverCompletes() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let applier = SyncFrameApplier(
            store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() },
            maxQueuedDeltaRecords: 3
        )
        // Open a snapshot that never completes, then flood deltas mid-paging.
        try await applier.apply(.snapshot(collection: COLL, snapshotRev: 9, epoch: 1, records: [], complete: false))
        try await applier.apply(.delta(collection: COLL, rev: 10, records: [try deviceRecord(id: "dev-A", rev: 10)]))
        try await applier.apply(.delta(collection: COLL, rev: 11, records: [try deviceRecord(id: "dev-B", rev: 11)]))
        // 2 records queued, ceiling 3: a 2-record delta pushes to 4 > 3, reject.
        await #expect(throws: SyncFrameParseError.self) {
            try await applier.apply(.delta(collection: COLL, rev: 12, records: [
                try deviceRecord(id: "dev-C", rev: 12), try deviceRecord(id: "dev-D", rev: 12),
            ]))
        }
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).isEmpty)
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 0)
    }

    @Test func oversizedSingleQueuedDeltaIsRejectedByRecordBound() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let applier = SyncFrameApplier(
            store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() },
            maxQueuedDeltaRecords: 2
        )
        try await applier.apply(.snapshot(collection: COLL, snapshotRev: 9, epoch: 1, records: [], complete: false))
        // A SINGLE oversized delta (3 records > ceiling 2) must be rejected: a
        // frame-COUNT bound would have let this one delta through.
        await #expect(throws: SyncFrameParseError.self) {
            try await applier.apply(.delta(collection: COLL, rev: 10, records: [
                try deviceRecord(id: "dev-A", rev: 10),
                try deviceRecord(id: "dev-B", rev: 10),
                try deviceRecord(id: "dev-C", rev: 10),
            ]))
        }
    }

    @Test func emptyDeltaFloodDuringPagingIsBoundedByFrameCount() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Generous record bound but a tight FRAME bound: a producer flooding empty
        // (`records: []`) deltas contributes 0 to the record bound, so only the
        // independent frame bound can stop the unbounded queue growth.
        let applier = SyncFrameApplier(
            store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() },
            maxQueuedDeltaRecords: 1_000, maxQueuedDeltaFrames: 2
        )
        try await applier.apply(.snapshot(collection: COLL, snapshotRev: 9, epoch: 1, records: [], complete: false))
        try await applier.apply(.delta(collection: COLL, rev: 10, records: []))
        try await applier.apply(.delta(collection: COLL, rev: 11, records: []))
        // 2 empty deltas queued, frame ceiling 2: the 3rd must be rejected even
        // though the record count is still 0.
        await #expect(throws: SyncFrameParseError.self) {
            try await applier.apply(.delta(collection: COLL, rev: 12, records: []))
        }
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).isEmpty)
        #expect(try await store.cursor(teamID: TEAM, collection: COLL) == 0)
    }

    @Test func frameForUnrequestedCollectionIsRejected() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Allowlist = {COLL} only. A misbehaving endpoint streaming snapshots/
        // deltas/ticks for other collection names must be rejected so it cannot
        // grow `builds` (or create cursor state) for an unbounded set of
        // unrequested collections.
        let applier = SyncFrameApplier(
            store: store, teamID: TEAM, sortKeyFor: sortKey, now: { Date() },
            allowedCollections: [COLL]
        )
        await #expect(throws: SyncFrameParseError.self) {
            try await applier.apply(.snapshot(collection: "evil-coll", snapshotRev: 1, epoch: 1, records: [], complete: false))
        }
        await #expect(throws: SyncFrameParseError.self) {
            try await applier.apply(.delta(collection: "evil-coll", rev: 1, records: []))
        }
        await #expect(throws: SyncFrameParseError.self) {
            try await applier.apply(.tick(collection: "evil-coll", rev: 1))
        }
        // The requested collection still applies normally; no cursor state leaked
        // for the rejected collection.
        try await applier.apply(.delta(collection: COLL, rev: 1, records: [try deviceRecord(id: "dev-A", rev: 1)]))
        #expect(try await store.liveRecords(teamID: TEAM, collection: COLL).count == 1)
        #expect(try await store.cursor(teamID: TEAM, collection: "evil-coll") == 0)
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
        #expect(try await applier.apply(.snapshot(collection: COLL, snapshotRev: 2, epoch: 1, records: [try deviceRecord(id: "dev-A", rev: 1)], complete: false)) == false)
        // A delta mid-paging is queued — no commit.
        #expect(try await applier.apply(.delta(collection: COLL, rev: 3, records: [try deviceRecord(id: "dev-B", rev: 3)])) == false)
        // The completing page commits => true.
        #expect(try await applier.apply(.snapshot(collection: COLL, snapshotRev: 2, epoch: 1, records: [], complete: true)) == true)
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
        let snap = try SyncFrameCodec().parse(Data(#"{"type":"sync.snapshot","collection":"devices","snapshotRev":7,"epoch":42,"records":[{"id":"a","rev":3,"updatedAt":1,"deleted":false,"payload":{"x":1}}],"complete":true}"#.utf8))
        #expect(snap == .snapshot(collection: "devices", snapshotRev: 7, epoch: 42,
            records: [SyncWireRecord(id: "a", rev: 3, updatedAt: 1, deleted: false, schemaVersion: syncSchemaVersion, payloadJSON: Data(#"{"x":1}"#.utf8))],
            complete: true))

        if case let .delta(collection, rev, records) = try SyncFrameCodec().parse(Data(#"{"type":"sync.delta","collection":"devices","rev":9,"records":[]}"#.utf8)) {
            #expect(collection == "devices"); #expect(rev == 9); #expect(records.isEmpty)
        } else { Issue.record("expected delta") }

        #expect(try SyncFrameCodec().parse(Data(#"{"type":"sync.tick","collection":"devices","rev":9}"#.utf8)) == .tick(collection: "devices", rev: 9))
    }

    @Test func presenceFramesParseAsUnknown() throws {
        // A presence frame on the shared socket is not a sync frame.
        #expect(try SyncFrameCodec().parse(Data(#"{"type":"online","instance":{}}"#.utf8)) == .unknown)
        #expect(try SyncFrameCodec().parse(Data(#"{"type":"snapshot","devices":[]}"#.utf8)) == .unknown)
    }

    @Test func nonJSONThrows() {
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec().parse(Data("not json".utf8))
        }
    }

    @Test func deltaOrSnapshotWithoutRecordsArrayThrows() {
        // A frame claiming to be sync but missing/wrong-typed `records` must
        // throw, so the client resyncs instead of committing an empty frame that
        // would silently advance the cursor / reconcile against nothing.
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec().parse(Data(#"{"type":"sync.delta","collection":"devices","rev":9}"#.utf8))
        }
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec().parse(Data(#"{"type":"sync.snapshot","collection":"devices","snapshotRev":9,"complete":true,"records":"oops"}"#.utf8))
        }
    }

    @Test func liveRecordWithoutPayloadIsMalformedNotSilentlyEmpty() {
        // A LIVE (non-deleted) record missing its payload must throw, not be
        // stored as `{}` (which the facade can't decode, hiding the row while the
        // cursor advances past it — a durable lost row with no resync).
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec().parse(Data(#"{"type":"sync.delta","collection":"devices","rev":2,"records":[{"id":"a","rev":2,"deleted":false}]}"#.utf8))
        }
        // A tombstone (deleted) with no payload is fine — its payload is never read.
        let frame = try? SyncFrameCodec().parse(Data(#"{"type":"sync.delta","collection":"devices","rev":2,"records":[{"id":"a","rev":2,"deleted":true}]}"#.utf8))
        if case let .delta(_, _, records) = frame {
            #expect(records.first?.deleted == true)
        } else { Issue.record("expected delta with a tombstone") }
    }

    @Test func booleanOrNegativeRevIsMalformed() {
        // `rev: true` (a JSON bool, bridged to a CFBoolean NSNumber) must not
        // parse as 1; a negative rev is impossible. Both force .malformed.
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec().parse(Data(#"{"type":"sync.delta","collection":"devices","rev":true,"records":[]}"#.utf8))
        }
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec().parse(Data(#"{"type":"sync.delta","collection":"devices","rev":-1,"records":[]}"#.utf8))
        }
        // A snapshot with a boolean snapshotRev is also malformed.
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec().parse(Data(#"{"type":"sync.snapshot","collection":"devices","snapshotRev":false,"complete":true,"records":[]}"#.utf8))
        }
    }

    @Test func hugeOrNonIntegralRevIsMalformedNotACrash() {
        // A valid JSON sync frame with an out-of-Int-range numeric rev must
        // surface .malformed (→ resync), never trap the process on Int(d).
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec().parse(Data(#"{"type":"sync.delta","collection":"devices","rev":1e100,"records":[]}"#.utf8))
        }
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec().parse(Data(#"{"type":"sync.snapshot","collection":"devices","snapshotRev":1e308,"complete":true,"records":[]}"#.utf8))
        }
        // The exact 2^63 boundary (Int.max rounds UP to this as a Double) must be
        // rejected, not trap on Int(d).
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec().parse(Data(#"{"type":"sync.delta","collection":"devices","rev":9223372036854775808,"records":[]}"#.utf8))
        }
    }

    @Test func recordRevAboveFrameHeadIsMalformed() {
        // A forged/malformed frame whose head is `rev: 5` but carries a record at
        // `rev: 1000000` must be rejected before it can poison the local cache:
        // persisting the poison-high rev would make the per-record monotone guard
        // ignore every legitimate future update for that id until the server's head
        // catches up. Throwing forces a clean resync instead.
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec().parse(Data(#"{"type":"sync.delta","collection":"devices","rev":5,"records":[{"id":"dev-A","rev":1000000,"payload":{}}]}"#.utf8))
        }
        // Same gap for a snapshot: a record rev above snapshotRev is malformed.
        #expect(throws: SyncFrameParseError.self) {
            _ = try SyncFrameCodec().parse(Data(#"{"type":"sync.snapshot","collection":"devices","snapshotRev":3,"complete":true,"records":[{"id":"dev-A","rev":9,"payload":{}}]}"#.utf8))
        }
        // A record rev EQUAL to the head is valid (the head advances to it).
        let ok = try? SyncFrameCodec().parse(Data(#"{"type":"sync.delta","collection":"devices","rev":7,"records":[{"id":"dev-A","rev":7,"payload":{}}]}"#.utf8))
        #expect(ok == .delta(collection: "devices", rev: 7, records: [SyncWireRecord(id: "dev-A", rev: 7, updatedAt: 0, deleted: false, schemaVersion: syncSchemaVersion, payloadJSON: Data("{}".utf8))]))
    }

    @Test func helloEncodesCollectionsCursorsAndEpochs() throws {
        let data = try SyncFrameCodec().encodeHello(collections: [("devices", 12, 99)])
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["type"] as? String == "sync.hello")
        #expect(obj["protocol"] as? String == syncProtocolV1)
        let cols = try #require(obj["collections"] as? [[String: Any]])
        #expect(cols.first?["epoch"] as? Int == 99)
    }
}

@Suite struct FlagTests {
    @Test func envOverrideWins() {
        #expect(MobileDeviceListLocalFirst.resolved(environment: ["CMUX_MOBILE_DEVICE_LIST_LOCAL_FIRST": "1"], defaults: UserDefaults(suiteName: "flag-1")!, isDebugBuild: false).isEnabled)
        #expect(!MobileDeviceListLocalFirst.resolved(environment: ["CMUX_MOBILE_DEVICE_LIST_LOCAL_FIRST": "0"], defaults: UserDefaults(suiteName: "flag-2")!, isDebugBuild: true).isEnabled)
    }

    @Test func debugDefaultsOnReleaseDefaultsOff() {
        let suite = UserDefaults(suiteName: "flag-3")!
        suite.removePersistentDomain(forName: "flag-3")
        #expect(MobileDeviceListLocalFirst.resolved(environment: [:], defaults: suite, isDebugBuild: true).isEnabled)
        #expect(!MobileDeviceListLocalFirst.resolved(environment: [:], defaults: suite, isDebugBuild: false).isEnabled)
    }
}
