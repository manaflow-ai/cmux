import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import CmuxSyncStore
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior-level coverage for the live device-list projection. The sync store
/// is the durable cursor cache, while the shell remains responsible for scope,
/// visibility, and picker projection.
@MainActor
@Suite(.serialized) struct DeviceListRealtimeProjectionTests {
    private static let owner = "user-1"

    private struct NoopTransport: SyncTransport {
        func send(_ data: Data) async throws {}

        func frames() -> AsyncThrowingStream<Data, any Error> {
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
    }

    private struct FramesTransport: SyncTransport {
        let framesToSend: [Data]

        func send(_ data: Data) async throws {}

        func frames() -> AsyncThrowingStream<Data, any Error> {
            AsyncThrowingStream { continuation in
                for frame in framesToSend {
                    continuation.yield(frame)
                }
                continuation.finish()
            }
        }
    }

    private struct TestDefaults {
        let pairingHint: UserDefaults
        let multiMacAggregation: UserDefaults
        private let suiteNames: [String]

        init() {
            let suffix = UUID().uuidString
            let pairingName = "cmux-device-list-pairing-\(suffix)"
            let aggregationName = "cmux-device-list-aggregation-\(suffix)"
            self.suiteNames = [pairingName, aggregationName]
            self.pairingHint = UserDefaults(suiteName: pairingName)!
            self.multiMacAggregation = UserDefaults(suiteName: aggregationName)!
        }

        func cleanup() {
            for suiteName in suiteNames {
                UserDefaults.standard.removePersistentDomain(forName: suiteName)
            }
        }
    }

    private struct Registry: DeviceRegistryRefreshing {
        let result: DeviceRegistryListOutcome

        func freshRoutes(
            forMacDeviceID macDeviceID: String,
            instanceTag: String?
        ) async -> [CmxAttachRoute]? {
            nil
        }

        func listDevices() async -> DeviceRegistryListOutcome { result }
    }

    private func makeSyncStore() throws -> (CmuxSyncStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-device-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (
            try CmuxSyncStore(
                databaseURL: directory.appendingPathComponent("sync.sqlite3")
            ),
            directory
        )
    }

    private func device(
        _ id: String,
        displayName: String? = nil,
        lastSeenAt: Double = 1_750_000_000_000
    ) -> SyncedDeviceRecord {
        SyncedDeviceRecord(
            deviceId: id,
            platform: "mac",
            displayName: displayName ?? id,
            ownerUserId: Self.owner,
            lastSeenAtAtRev: lastSeenAt,
            instances: [
                .init(tag: "default", routes: [], lastSeenAtAtRev: lastSeenAt),
            ]
        )
    }

    private func wireRecord(_ record: SyncedDeviceRecord, rev: Int = 1) throws -> SyncWireRecord {
        SyncWireRecord(
            id: record.deviceId,
            rev: rev,
            updatedAt: record.lastSeenAtAtRev,
            deleted: false,
            schemaVersion: syncSchemaVersion,
            payloadJSON: try JSONEncoder().encode(record)
        )
    }

    private func registryDevice(_ id: String) -> RegistryDevice {
        RegistryDevice(
            deviceId: id,
            platform: "mac",
            displayName: id,
            lastSeenAt: Date(timeIntervalSince1970: 1_750_000_000),
            instances: [
                RegistryAppInstance(
                    tag: "default",
                    routes: [],
                    lastSeenAt: Date(timeIntervalSince1970: 1_750_000_000)
                ),
            ]
        )
    }

    private func transportFactory() -> @Sendable (String, String) -> any SyncTransport {
        { _, _ in NoopTransport() }
    }

    private func waitForDeviceList(
        _ shell: MobileShellComposite,
        expectedIDs: [String]
    ) async {
        for _ in 0..<100 {
            if shell.deviceTreeDevices.map(\.deviceId) == expectedIDs { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(shell.deviceTreeDevices.map(\.deviceId) == expectedIDs)
    }

    @Test func authoritativeSnapshotIsRenderedWithoutRegistryRoundTrip() async throws {
        let (syncStore, directory) = try makeSyncStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = TestDefaults()
        defer { defaults.cleanup() }
        let record = device("mac-live", displayName: "Live Mac")
        try await syncStore.applySnapshot(
            teamID: "team-a",
            collection: devicesSyncCollection,
            snapshotRev: 1,
            epoch: 1,
            records: [try wireRecord(record)],
            sortKeyFor: DeviceSyncFacade.sortKey(for:),
            now: Date()
        )

        let shell = MobileShellComposite(
            isSignedIn: true,
            deviceRegistry: Registry(result: .ok([registryDevice("stale-registry")])),
            syncStore: syncStore,
            deviceListLocalFirst: true,
            makeSyncTransport: transportFactory(),
            identityProvider: StaticIdentityProvider(userID: Self.owner),
            teamIDProvider: { "team-a" },
            deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
            pairingHintDefaults: defaults.pairingHint,
            multiMacAggregationDefaults: defaults.multiMacAggregation
        )

        await shell.loadRegistryDevices()

        #expect(shell.deviceTreeDevices.map(\.deviceId) == ["mac-live"])
        #expect(shell.deviceListAuthoritativeTeamID == "team-a")
    }

    @Test func cursorZeroFallsBackUntilTheFirstSnapshotCommits() async throws {
        let (syncStore, directory) = try makeSyncStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = TestDefaults()
        defer { defaults.cleanup() }

        let shell = MobileShellComposite(
            isSignedIn: true,
            deviceRegistry: Registry(result: .ok([registryDevice("registry-mac")])),
            syncStore: syncStore,
            deviceListLocalFirst: true,
            makeSyncTransport: transportFactory(),
            identityProvider: StaticIdentityProvider(userID: Self.owner),
            teamIDProvider: { "team-a" },
            deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
            pairingHintDefaults: defaults.pairingHint,
            multiMacAggregationDefaults: defaults.multiMacAggregation
        )

        await shell.loadRegistryDevices()

        #expect(shell.deviceTreeDevices.map(\.deviceId) == ["registry-mac"])
        #expect(shell.deviceListAuthoritativeTeamID == nil)
    }

    @Test func unavailableSyncStoreFailsClosedInsteadOfResurrectingPairedMacs() async throws {
        let defaults = TestDefaults()
        defer { defaults.cleanup() }
        let pairedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-paired-unavailable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pairedDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: pairedDirectory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: pairedDirectory.appendingPathComponent("paired.sqlite3")
        )
        try await pairedStore.upsert(
            macDeviceID: "signed-out-mac",
            displayName: "Signed Out Mac",
            routes: [],
            instanceTag: "default",
            markActive: true,
            stackUserID: Self.owner,
            teamID: "team-a",
            now: Date()
        )

        let shell = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            deviceRegistry: Registry(result: .ok([registryDevice("stale-registry")])),
            syncStore: nil,
            deviceListLocalFirst: true,
            makeSyncTransport: nil,
            identityProvider: StaticIdentityProvider(userID: Self.owner),
            teamIDProvider: { "team-a" },
            deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
            pairingHintDefaults: defaults.pairingHint,
            multiMacAggregationDefaults: defaults.multiMacAggregation
        )

        await shell.loadPairedMacs()
        await shell.loadRegistryDevices()

        #expect(shell.pairedMacs.map(\.macDeviceID) == ["signed-out-mac"])
        #expect(shell.deviceTreeDevices.isEmpty)
        #expect(shell.displayPairedMacs.isEmpty)
    }

    @Test func authoritativeEmptyRemovesRegistryAndPairedFallback() async throws {
        let (syncStore, syncDirectory) = try makeSyncStore()
        defer { try? FileManager.default.removeItem(at: syncDirectory) }
        let defaults = TestDefaults()
        defer { defaults.cleanup() }
        try await syncStore.applySnapshot(
            teamID: "team-a",
            collection: devicesSyncCollection,
            snapshotRev: 4,
            epoch: 1,
            records: [],
            sortKeyFor: DeviceSyncFacade.sortKey(for:),
            now: Date()
        )

        let pairedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-paired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pairedDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: pairedDirectory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: pairedDirectory.appendingPathComponent("paired.sqlite3")
        )
        try await pairedStore.upsert(
            macDeviceID: "signed-out-mac",
            displayName: "Signed Out Mac",
            routes: [],
            instanceTag: "default",
            markActive: true,
            stackUserID: Self.owner,
            teamID: "team-a",
            now: Date()
        )

        let shell = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            deviceRegistry: Registry(result: .ok([registryDevice("stale-registry")])),
            syncStore: syncStore,
            deviceListLocalFirst: true,
            makeSyncTransport: transportFactory(),
            identityProvider: StaticIdentityProvider(userID: Self.owner),
            teamIDProvider: { "team-a" },
            deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
            pairingHintDefaults: defaults.pairingHint,
            multiMacAggregationDefaults: defaults.multiMacAggregation
        )

        await shell.loadPairedMacs()
        await shell.loadRegistryDevices()

        #expect(shell.pairedMacs.map(\.macDeviceID) == ["signed-out-mac"])
        #expect(shell.deviceTreeDevices.isEmpty)
        #expect(shell.displayPairedMacs.isEmpty)
    }

    @Test func liveDeltaRemovesSignedOutMacWithoutReloadingTheShell() async throws {
        let (syncStore, syncDirectory) = try makeSyncStore()
        defer { try? FileManager.default.removeItem(at: syncDirectory) }
        let defaults = TestDefaults()
        defer { defaults.cleanup() }
        let live = device("mac-live")
        try await syncStore.applySnapshot(
            teamID: "team-a",
            collection: devicesSyncCollection,
            snapshotRev: 1,
            epoch: 1,
            records: [try wireRecord(live)],
            sortKeyFor: DeviceSyncFacade.sortKey(for:),
            now: Date()
        )
        let tombstone = SyncWireRecord(
            id: live.deviceId,
            rev: 2,
            updatedAt: live.lastSeenAtAtRev + 1,
            deleted: true,
            schemaVersion: syncSchemaVersion,
            payloadJSON: Data("{}".utf8)
        )
        let delta = try JSONSerialization.data(withJSONObject: [
            "type": "sync.delta",
            "collection": devicesSyncCollection,
            "rev": 2,
            "records": [[
                "id": tombstone.id,
                "rev": tombstone.rev,
                "updatedAt": tombstone.updatedAt,
                "deleted": true,
                "schemaVersion": tombstone.schemaVersion,
                "payload": [:],
            ]],
        ])
        let shell = MobileShellComposite(
            isSignedIn: true,
            deviceRegistry: Registry(result: .ok([registryDevice("stale-registry")])),
            syncStore: syncStore,
            deviceListLocalFirst: true,
            makeSyncTransport: { _, _ in FramesTransport(framesToSend: [delta]) },
            identityProvider: StaticIdentityProvider(userID: Self.owner),
            teamIDProvider: { "team-a" },
            deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
            pairingHintDefaults: defaults.pairingHint,
            multiMacAggregationDefaults: defaults.multiMacAggregation
        )

        await shell.loadRegistryDevices()
        #expect(shell.deviceTreeDevices.map(\.deviceId) == ["mac-live"])
        await waitForDeviceList(shell, expectedIDs: [])
        #expect(shell.displayPairedMacs.isEmpty)
    }

    @Test func authoritativeStateIsScopedToTheSelectedTeam() async throws {
        let (syncStore, directory) = try makeSyncStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = TestDefaults()
        defer { defaults.cleanup() }
        try await syncStore.applySnapshot(
            teamID: "team-a",
            collection: devicesSyncCollection,
            snapshotRev: 2,
            epoch: 1,
            records: [],
            sortKeyFor: DeviceSyncFacade.sortKey(for:),
            now: Date()
        )

        let pairedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-paired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pairedDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: pairedDirectory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: pairedDirectory.appendingPathComponent("paired.sqlite3")
        )
        try await pairedStore.upsert(
            macDeviceID: "team-b-mac",
            displayName: "Team B Mac",
            routes: [],
            instanceTag: "default",
            markActive: true,
            stackUserID: Self.owner,
            teamID: "team-b",
            now: Date()
        )

        let selectedTeam = MutableTeam("team-a")
        let shell = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            syncStore: syncStore,
            deviceListLocalFirst: true,
            makeSyncTransport: transportFactory(),
            identityProvider: StaticIdentityProvider(userID: Self.owner),
            teamIDProvider: { await selectedTeam.value },
            deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
            pairingHintDefaults: defaults.pairingHint,
            multiMacAggregationDefaults: defaults.multiMacAggregation
        )

        await shell.loadPairedMacs()
        await shell.loadRegistryDevices()
        #expect(shell.deviceTreeDevices.isEmpty)

        await selectedTeam.set("team-b")
        shell.currentTeamDidChange()
        await shell.loadPairedMacs()
        await shell.loadRegistryDevices()

        #expect(shell.deviceTreeDevices.map(\.deviceId) == ["team-b-mac"])
    }
}
