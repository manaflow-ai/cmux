import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxSyncStore

/// Tests for the guarantees the iOS device-list wiring must hold: devices
/// survive an app update, and a fresh sign-in on another device sees them.
/// (Shared helpers `TEAM`/`COLL`/`T0_MS`/`makeStore`/`deviceRecord`/`sortKey`
/// live in `CmuxSyncStoreTests.swift` in this same test target.)
@Suite struct DeviceListUpdateSurvivalTests {
    /// The core guarantee: device records written to the on-disk sync store are
    /// still there — with display name, and resumable cursor/epoch — when a
    /// brand-new store + facade open the same file, which is exactly what an app
    /// version update does (same Application Support path, new process).
    @Test func devicesSurviveStoreReopenAcrossUpdate() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cmux-sync.sqlite3")

        // First app version: a devices snapshot from the DO lands and commits.
        do {
            let store = try CmuxSyncStore(databaseURL: url)
            try await store.applySnapshot(
                teamID: TEAM, collection: COLL, snapshotRev: 2, epoch: 1,
                records: [
                    try deviceRecord(id: "mac-A", rev: 1, displayName: "Lawrence's MacBook Pro"),
                    try deviceRecord(id: "mac-B", rev: 2, displayName: "Studio"),
                ],
                sortKeyFor: sortKey, now: Date()
            )
        }

        // Second app version: a fresh store + facade on the same file (update).
        let reopened = try CmuxSyncStore(databaseURL: url)
        let devices = try await DeviceSyncFacade(store: reopened).registryDevices(teamID: TEAM)
        #expect(Set(devices.map(\.deviceId)) == ["mac-A", "mac-B"])
        #expect(devices.first(where: { $0.deviceId == "mac-A" })?.displayName == "Lawrence's MacBook Pro")
        // Cursor + epoch persisted, so the next launch resumes via deltas (no
        // wholesale re-snapshot, and no window where the list is empty).
        #expect(try await reopened.cursor(teamID: TEAM, collection: COLL) == 2)
        #expect(try await reopened.epoch(teamID: TEAM, collection: COLL) == 1)
    }

    /// First-launch-after-update seeding: a provisional row from the local
    /// paired-Mac migration renders via the facade AND survives a later DO
    /// snapshot that does not know about that Mac (offline at update time), so an
    /// existing device is never lost.
    @Test func provisionalSeedRendersAndSurvivesSnapshotOmission() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The migration seeds the phone's existing Mac as a provisional rev==0 row.
        let provisional = try JSONEncoder().encode(SyncedDeviceRecord(
            deviceId: "mac-local", platform: "mac", displayName: "Old Mac", ownerUserId: "user-A",
            lastSeenAtAtRev: T0_MS,
            instances: [.init(tag: "default", routes: [], lastSeenAtAtRev: T0_MS)]
        ))
        try await store.seedProvisional(
            teamID: TEAM, collection: COLL, recordID: "mac-local",
            payloadJSON: provisional, sortKey: T0_MS, now: Date()
        )
        // A DO snapshot arrives that only knows a DIFFERENT device.
        try await store.applySnapshot(
            teamID: TEAM, collection: COLL, snapshotRev: 1, epoch: 1,
            records: [try deviceRecord(id: "mac-other", rev: 1)],
            sortKeyFor: sortKey, now: Date()
        )

        let devices = try await DeviceSyncFacade(store: store)
            .registryDevices(teamID: TEAM, provisionalOwnerUserID: "user-A")
        #expect(Set(devices.map(\.deviceId)) == ["mac-local", "mac-other"])
    }
}

@Suite struct DeviceListCrossDeviceReadTests {
    /// Replays a scripted frame set; records nothing it does not need to.
    final class ScriptedTransport: SyncTransport, @unchecked Sendable {
        let scripted: [Data]
        init(scripted: [Data]) { self.scripted = scripted }
        func send(_ data: Data) async throws {}
        func frames() -> AsyncThrowingStream<Data, any Error> {
            AsyncThrowingStream { continuation in
                for frame in scripted { continuation.yield(frame) }
                continuation.finish()
            }
        }
    }

    /// Cross-device "just works": a `devices` snapshot the Mac published (so, a
    /// device the user only ever paired from ANOTHER phone) streams over the
    /// transport, lands in the local store, and renders via the facade with no
    /// local pairing on this device.
    @Test func snapshotFromAnotherDeviceRendersLocally() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let applier = SyncFrameApplier(store: store, teamID: TEAM, sortKeyFor: sortKey)
        let snapshot = Data(#"{"type":"sync.snapshot","collection":"devices","snapshotRev":1,"records":[{"id":"mac-remote","rev":1,"updatedAt":1,"deleted":false,"payload":{"deviceId":"mac-remote","platform":"mac","displayName":"Office Mac","lastSeenAtAtRev":1750000000000,"instances":[]}}],"complete":true}"#.utf8)
        // A presence tick shares the socket; the client must ignore it.
        let presenceNoise = Data(#"{"type":"seen","deviceId":"mac-remote","tag":"default","lastSeenAt":1}"#.utf8)
        let client = SyncClient(
            transport: ScriptedTransport(scripted: [presenceNoise, snapshot]),
            applier: applier,
            collections: [COLL]
        )
        try await client.run()

        let devices = try await DeviceSyncFacade(store: store).registryDevices(teamID: TEAM)
        #expect(devices.map(\.deviceId) == ["mac-remote"])
        #expect(devices.first?.displayName == "Office Mac")
    }

    /// Account isolation on a shared device: a provisional (rev==0) row is one
    /// account's local seed and is visible only to that account; authoritative
    /// (rev>=1) DO rows are team-shared and visible to everyone on the team.
    @Test func provisionalRowsAreOwnerScopedAuthoritativeShared() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        func provisional(_ id: String, owner: String) throws -> Data {
            try JSONEncoder().encode(SyncedDeviceRecord(
                deviceId: id, platform: "mac", displayName: id, ownerUserId: owner,
                lastSeenAtAtRev: T0_MS, instances: []
            ))
        }
        try await store.seedProvisional(teamID: TEAM, collection: COLL, recordID: "mac-A",
            payloadJSON: try provisional("mac-A", owner: "user-A"), sortKey: T0_MS, now: Date())
        try await store.seedProvisional(teamID: TEAM, collection: COLL, recordID: "mac-B",
            payloadJSON: try provisional("mac-B", owner: "user-B"), sortKey: T0_MS, now: Date())
        // A team-shared authoritative device from the DO.
        try await store.applySnapshot(teamID: TEAM, collection: COLL, snapshotRev: 1, epoch: 1,
            records: [try deviceRecord(id: "mac-shared", rev: 1)], sortKeyFor: sortKey, now: Date())

        let facade = DeviceSyncFacade(store: store)
        let asA = try await facade.registryDevices(teamID: TEAM, provisionalOwnerUserID: "user-A")
        #expect(Set(asA.map(\.deviceId)) == ["mac-A", "mac-shared"])
        let asB = try await facade.registryDevices(teamID: TEAM, provisionalOwnerUserID: "user-B")
        #expect(Set(asB.map(\.deviceId)) == ["mac-B", "mac-shared"])
        // Owner unknown (nil) fails closed: only the team-shared authoritative
        // row, never another account's local-only provisional rows.
        let unknownOwner = try await facade.registryDevices(teamID: TEAM)
        #expect(Set(unknownOwner.map(\.deviceId)) == ["mac-shared"])
    }
}
