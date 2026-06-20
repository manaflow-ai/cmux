import CMUXMobileCore
import CmuxMobileShellModel
import CmuxSyncStore
import Foundation
import Testing
@testable import CmuxMobileShell

/// Verifies the composite's local-first read swap and its coherence with the
/// sync transport gating: the device tree reads the durable sync store when the
/// flag + transport are wired (no XOR masking), falls back to the registry when
/// sync cannot run or the store is empty, ignores the store when the flag is
/// off, and never lets a stale-team frame overwrite the current team's list.
@MainActor
@Suite struct DeviceListLocalFirstWiringTests {
    /// A transport that is never actually driven in these tests; its mere
    /// presence satisfies the read-swap's transport-availability gate.
    struct NoopSyncTransport: SyncTransport {
        func send(_ data: Data) async throws {}
        func frames() -> AsyncThrowingStream<Data, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// A device registry returning a scripted `listDevices` outcome.
    struct FakeDeviceRegistry: DeviceRegistryRefreshing {
        let outcome: DeviceRegistryListOutcome
        func freshRoutes(forMacDeviceID macDeviceID: String) async -> [CmxAttachRoute]? { nil }
        func listDevices() async -> DeviceRegistryListOutcome { outcome }
    }

    private func makeTransportFactory() -> @Sendable (String) -> any SyncTransport {
        { _ in NoopSyncTransport() }
    }

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

    private func emptySyncStore() throws -> (CmuxSyncStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try CmuxSyncStore(databaseURL: dir.appendingPathComponent("cmux-sync.sqlite3")), dir)
    }

    private func registryDevice(_ id: String) -> RegistryDevice {
        RegistryDevice(deviceId: id, platform: "mac", displayName: id, lastSeenAt: Date(),
                       instances: [RegistryAppInstance(tag: "default", routes: [], lastSeenAt: Date())])
    }

    @Test func deviceTreeReadsSyncStoreWhenFlagAndTransportWired() async throws {
        let (store, dir) = try await seededSyncStore(team: "team-1", deviceIDs: ["mac-A", "mac-B"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let composite = MobileShellComposite(
            isSignedIn: true,
            syncStore: store,
            deviceListLocalFirst: true,
            syncTeamIDProvider: { "team-1" },
            makeSyncTransport: makeTransportFactory(),
            deliveredNotificationClearer: NoopDeliveredNotificationClearer()
        )
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
            makeSyncTransport: makeTransportFactory(),
            deliveredNotificationClearer: NoopDeliveredNotificationClearer()
        )
        await composite.loadRegistryDevices()
        #expect(composite.deviceTreeDevices.isEmpty)
    }

    /// Finding #1a: flag on but no transport (e.g. Release without a presence URL)
    /// must NOT bypass the registry — it falls through to `/api/devices`.
    @Test func flagOnWithoutTransportUsesRegistry() async throws {
        let (store, dir) = try await seededSyncStore(team: "team-1", deviceIDs: ["mac-local"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let composite = MobileShellComposite(
            isSignedIn: true,
            deviceRegistry: FakeDeviceRegistry(outcome: .ok([registryDevice("mac-registry")])),
            syncStore: store,
            deviceListLocalFirst: true,
            syncTeamIDProvider: { "team-1" },
            makeSyncTransport: nil, // no transport → sync can't run
            deliveredNotificationClearer: NoopDeliveredNotificationClearer()
        )
        await composite.loadRegistryDevices()
        #expect(composite.deviceTreeDevices.map(\.deviceId) == ["mac-registry"])
    }

    /// Finding #1b: flag + transport on but the local store is still empty (DO
    /// unreachable / pre-seed) must fall back to the registry, not show empty.
    @Test func emptyStoreFallsBackToRegistry() async throws {
        let (store, dir) = try emptySyncStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let composite = MobileShellComposite(
            isSignedIn: true,
            deviceRegistry: FakeDeviceRegistry(outcome: .ok([registryDevice("mac-registry")])),
            syncStore: store,
            deviceListLocalFirst: true,
            syncTeamIDProvider: { "team-1" },
            makeSyncTransport: makeTransportFactory(),
            deliveredNotificationClearer: NoopDeliveredNotificationClearer()
        )
        await composite.loadRegistryDevices()
        #expect(composite.deviceTreeDevices.map(\.deviceId) == ["mac-registry"])
    }

    /// Once the DO has synced (cursor > 0), an empty team is AUTHORITATIVELY
    /// empty and must not resurrect stale registry rows the DO removed.
    @Test func authoritativeEmptyDoesNotFallBackToRegistry() async throws {
        let (store, dir) = try emptySyncStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // An empty snapshot advances the cursor: synced, and genuinely no devices.
        try await store.applySnapshot(
            teamID: "team-1", collection: devicesSyncCollection, snapshotRev: 5, epoch: 1,
            records: [], sortKeyFor: { DeviceSyncFacade.sortKey(for: $0) }, now: Date()
        )
        let composite = MobileShellComposite(
            isSignedIn: true,
            deviceRegistry: FakeDeviceRegistry(outcome: .ok([registryDevice("mac-stale")])),
            syncStore: store,
            deviceListLocalFirst: true,
            syncTeamIDProvider: { "team-1" },
            makeSyncTransport: makeTransportFactory(),
            deliveredNotificationClearer: NoopDeliveredNotificationClearer()
        )
        await composite.loadRegistryDevices()
        #expect(composite.deviceTreeDevices.isEmpty)
    }

    /// Finding #2: a late frame for the OLD team (a team switch mid-stream) must
    /// not overwrite the current team's list.
    @Test func staleTeamFrameDoesNotOverwriteCurrentTeam() async throws {
        let (store, dir) = try await seededSyncStore(team: "team-A", deviceIDs: ["mac-A"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let composite = MobileShellComposite(
            isSignedIn: true,
            syncStore: store,
            deviceListLocalFirst: true,
            syncTeamIDProvider: { "team-B" }, // user is now on team-B
            makeSyncTransport: makeTransportFactory(),
            deliveredNotificationClearer: NoopDeliveredNotificationClearer()
        )
        // Simulate an old-team-A frame's onApplied landing after the switch.
        await composite.reloadDeviceListFromSyncStore(teamID: "team-A")
        #expect(composite.deviceTreeDevices.isEmpty)
    }
}
