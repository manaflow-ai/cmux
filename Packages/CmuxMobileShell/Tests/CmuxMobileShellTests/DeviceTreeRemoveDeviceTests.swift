import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for ``MobileShellComposite/removeDevice(deviceID:)`` routing:
/// a registry-backed device must be deleted from the team-scoped registry AND
/// dropped from the local paired-Mac store, while a device known only locally
/// (registry empty, fallback tree) must be forgotten locally WITHOUT a registry
/// `DELETE` call. This is the exact split the Devices sheet's remove affordance
/// depends on, so it is covered at the store-behavior level rather than the UI.
@MainActor
@Suite struct DeviceTreeRemoveDeviceTests {
    private static func makeStore(
        pairedMacStore: any MobilePairedMacStoring,
        registry: RecordingDeviceRegistry
    ) -> MobileShellComposite {
        MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            deviceRegistry: registry,
            identityProvider: FixedIdentityProvider(userID: "user-1")
        )
    }

    private static func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("device-tree-remove-\(UUID().uuidString).sqlite3")
    }

    @Test func removingRegistryBackedDeviceDeletesRegistryRowAndLocalPairing() async throws {
        let dbURL = Self.temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let paired = try MobilePairedMacStore(databaseURL: dbURL)
        // The device exists both in the local store and the registry tree.
        try await paired.upsert(
            macDeviceID: "dev-registry",
            displayName: "Registry Mac",
            routes: [],
            markActive: false,
            stackUserID: "user-1"
        )
        let registry = RecordingDeviceRegistry(initialDevices: [
            RegistryDevice(
                deviceId: "dev-registry",
                platform: "mac",
                displayName: "Registry Mac",
                lastSeenAt: .distantPast,
                instances: []
            )
        ])
        let store = Self.makeStore(pairedMacStore: paired, registry: registry)
        await store.loadPairedMacs()
        await store.loadRegistryDevices()
        #expect(store.registryDevices.contains { $0.deviceId == "dev-registry" })

        await store.removeDevice(deviceID: "dev-registry")

        // Registry-backed: the server DELETE ran for exactly this device id...
        #expect(await registry.removedDeviceIDs == ["dev-registry"])
        // ...the tree reload reflects the server having dropped the row...
        #expect(store.registryDevices.contains { $0.deviceId == "dev-registry" } == false)
        // ...and the local pairing was dropped so it cannot silently reconnect.
        let remaining = try await paired.loadAll(stackUserID: "user-1")
        #expect(remaining.contains { $0.macDeviceID == "dev-registry" } == false)
    }

    @Test func removingLocalOnlyDeviceForgetsLocallyWithoutRegistryDelete() async throws {
        let dbURL = Self.temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let paired = try MobilePairedMacStore(databaseURL: dbURL)
        try await paired.upsert(
            macDeviceID: "dev-local",
            displayName: "Local Mac",
            routes: [],
            markActive: false,
            stackUserID: "user-1"
        )
        // Registry returns no devices: the tree falls back to local paired Macs,
        // so this device is local-only and must not trigger a registry DELETE.
        let registry = RecordingDeviceRegistry(initialDevices: [])
        let store = Self.makeStore(pairedMacStore: paired, registry: registry)
        await store.loadPairedMacs()
        await store.loadRegistryDevices()
        #expect(store.registryDevices.isEmpty)

        await store.removeDevice(deviceID: "dev-local")

        // Local-only: no registry DELETE was attempted...
        #expect(await registry.removedDeviceIDs.isEmpty)
        // ...but the local pairing was forgotten.
        let remaining = try await paired.loadAll(stackUserID: "user-1")
        #expect(remaining.contains { $0.macDeviceID == "dev-local" } == false)
    }
}

/// A stateful ``DeviceRegistryRefreshing`` test double. `listDevices` returns its
/// current device set and `removeDevice` deletes from it (recording the call), so
/// the store's `loadRegistryDevices()` reconcile after a remove sees the row gone
/// exactly as it would against the real server.
private actor RecordingDeviceRegistry: DeviceRegistryRefreshing {
    private(set) var removedDeviceIDs: [String] = []
    private var devices: [RegistryDevice]

    init(initialDevices: [RegistryDevice]) {
        self.devices = initialDevices
    }

    func freshRoutes(forMacDeviceID macDeviceID: String) async -> [CmxAttachRoute]? { nil }

    func listDevices() async -> DeviceRegistryListOutcome { .ok(devices) }

    func removeDevice(deviceID: String) async -> Bool {
        removedDeviceIDs.append(deviceID)
        let before = devices.count
        devices.removeAll { $0.deviceId == deviceID }
        return devices.count != before
    }
}

private struct FixedIdentityProvider: MobileIdentityProviding {
    let userID: String?
    var currentUserID: String? { userID }
    var currentUserEmail: String? { nil }
}
