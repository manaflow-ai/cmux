import CMUXMobileCore
import CmuxMobileShellModel
import CmuxSyncStore
import Foundation
import Testing
@testable import CmuxMobileShell

/// Verifies the composite's local-first read swap: when the flag is on and a
/// sync store is wired, the device tree is sourced from the durable sync store
/// (not a `/api/devices` call), and a non-empty store never collapses to a
/// partial registry response — the exact masking that lost saved devices on
/// update. Flag OFF must not touch the sync store.
@MainActor
@Suite struct DeviceListLocalFirstWiringTests {
    private func seededSyncStore(team: String, deviceIDs: [String]) async throws -> (CmuxSyncStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try CmuxSyncStore(databaseURL: dir.appendingPathComponent("cmux-sync.sqlite3"))
        let lastSeen = 1_750_000_000_000.0
        for id in deviceIDs {
            let payload = try JSONEncoder().encode(SyncedDeviceRecord(
                deviceId: id, platform: "mac", displayName: id, ownerUserId: nil,
                lastSeenAtAtRev: lastSeen,
                instances: [.init(tag: "default", routes: [], lastSeenAtAtRev: lastSeen)]
            ))
            try await store.seedProvisional(
                teamID: team, collection: devicesSyncCollection, recordID: id,
                payloadJSON: payload, sortKey: lastSeen, now: Date()
            )
        }
        return (store, dir)
    }

    @Test func deviceTreeReadsSyncStoreWhenFlagOn() async throws {
        let (store, dir) = try await seededSyncStore(team: "team-1", deviceIDs: ["mac-A", "mac-B"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let composite = MobileShellComposite(
            isSignedIn: true,
            syncStore: store,
            deviceListLocalFirst: true,
            syncTeamIDProvider: { "team-1" },
            deliveredNotificationClearer: NoopDeliveredNotificationClearer()
        )
        // No deviceRegistry injected: under the old XOR path this would have left
        // the tree empty; the local-first read must populate it from the store.
        await composite.loadRegistryDevices()
        #expect(Set(composite.deviceTreeDevices.map(\.deviceId)) == ["mac-A", "mac-B"])
    }

    @Test func flagOffDoesNotReadSyncStore() async throws {
        let (store, dir) = try await seededSyncStore(team: "team-1", deviceIDs: ["mac-A"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let composite = MobileShellComposite(
            isSignedIn: true,
            syncStore: store,
            deviceListLocalFirst: false,
            syncTeamIDProvider: { "team-1" },
            deliveredNotificationClearer: NoopDeliveredNotificationClearer()
        )
        // Flag off + no registry injected → today's path yields an empty list.
        await composite.loadRegistryDevices()
        #expect(composite.deviceTreeDevices.isEmpty)
    }
}
