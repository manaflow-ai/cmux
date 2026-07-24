import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohCustomPrivatePathStoreTests {
    private let macA = "123e4567-e89b-42d3-a456-426614174004"
    private let macB = "123e4567-e89b-42d3-a456-426614174005"

    @Test
    func preferencesRemainDeviceLocalAccountScopedAndExactMacScoped() async throws {
        let installState = CustomPrivatePathMemoryStore()
        let store = CmxIrohCustomPrivatePathStore(store: installState)
        let saved = try await store.upsert(
            CmxIrohCustomPrivatePathDraft(
                macDeviceID: macA.uppercased(),
                macDisplayName: " Work Mac ",
                addresses: ["10.0.0.8", "10.0.0.8", "fd00::8"],
                isEnabled: true
            ),
            accountID: "account-a"
        )

        #expect(saved.generation == 2)
        #expect(saved.configurations.count == 1)
        #expect(saved.configurations[0].macDeviceID == macA)
        #expect(saved.configurations[0].macDisplayName == "Work Mac")
        #expect(saved.configurations[0].addresses.map(\.value) == ["10.0.0.8", "fd00::8"])
        #expect(saved.activeNetworkProfiles.count == 1)
        #expect(await store.enabledPaths(
            forMacDeviceID: macA,
            accountID: "account-a"
        ).map(\.address.value) == ["10.0.0.8", "fd00::8"])
        #expect(await store.enabledPaths(
            forMacDeviceID: macB,
            accountID: "account-a"
        ).isEmpty)
        #expect(await store.enabledPaths(
            forMacDeviceID: macA,
            accountID: "account-b"
        ).isEmpty)

        let restored = CmxIrohCustomPrivatePathStore(store: installState)
        #expect(try await restored.snapshot(accountID: "account-a") == saved)
    }

    @Test
    func disabledAndRemovedPreferencesRevokeProfileAuthority() async throws {
        let store = CmxIrohCustomPrivatePathStore(
            store: CustomPrivatePathMemoryStore()
        )
        _ = try await store.upsert(
            CmxIrohCustomPrivatePathDraft(
                macDeviceID: macA,
                macDisplayName: "Work Mac",
                addresses: ["10.0.0.8"],
                isEnabled: false
            ),
            accountID: "account-a"
        )
        let disabled = try await store.snapshot(accountID: "account-a")
        #expect(disabled.activeNetworkProfiles.isEmpty)
        #expect(await store.enabledPaths(
            forMacDeviceID: macA,
            accountID: "account-a"
        ).isEmpty)

        let removed = try await store.remove(
            macDeviceID: macA,
            accountID: "account-a"
        )
        #expect(removed.generation == disabled.generation + 1)
        #expect(removed.configurations.isEmpty)
        #expect(removed.activeNetworkProfiles.isEmpty)
    }

    @Test
    func invalidInputCannotEnterPersistence() async {
        let store = CmxIrohCustomPrivatePathStore(
            store: CustomPrivatePathMemoryStore()
        )
        for addresses in [
            ["private.example.com"],
            ["127.0.0.1"],
            ["10.0.0.8:49152"],
        ] {
            await #expect(throws: CmxIrohCustomPrivateAddressError.invalidAddress) {
                _ = try await store.upsert(
                    CmxIrohCustomPrivatePathDraft(
                        macDeviceID: macA,
                        macDisplayName: "Work Mac",
                        addresses: addresses,
                        isEnabled: true
                    ),
                    accountID: "account-a"
                )
            }
        }
    }

    @Test
    func malformedDeviceLocalStateFailsClosed() async throws {
        let installState = CustomPrivatePathMemoryStore()
        let scope = try CmxIrohRelayStorageScope.account(
            "account-a",
            prefix: "custom-private-paths"
        )
        installState.set("not-base64", forKey: scope)
        let store = CmxIrohCustomPrivatePathStore(store: installState)

        #expect(await store.availableSnapshot(accountID: "account-a") == .unavailable)
        #expect(await store.enabledPaths(
            forMacDeviceID: macA,
            accountID: "account-a"
        ).isEmpty)
    }

    @Test
    func composerChangesGenerationWhenEitherAuthorityChanges() async throws {
        let platformProfile = try CmxIrohNetworkProfileKey(
            source: .tailscale,
            profileID: opaqueProfileID("platform")
        )
        let customProfile = try CmxIrohNetworkProfileKey(
            source: .customVPN,
            profileID: opaqueProfileID("custom")
        )
        let composer = CmxIrohNetworkPathSnapshotComposer()
        let platform = CmxIrohNetworkPathSnapshot(
            generation: 8,
            activeNetworkProfiles: [platformProfile]
        )
        let custom = CmxIrohCustomPrivatePathSnapshot(
            generation: 2,
            configurations: [],
            activeNetworkProfiles: [customProfile]
        )

        let first = await composer.compose(platform: platform, custom: custom)
        let same = await composer.compose(platform: platform, custom: custom)
        let changed = await composer.compose(
            platform: platform,
            custom: CmxIrohCustomPrivatePathSnapshot(
                generation: 3,
                configurations: [],
                activeNetworkProfiles: []
            )
        )

        #expect(first.generation == same.generation)
        #expect(first.activeNetworkProfiles == [platformProfile, customProfile])
        #expect(changed.generation == first.generation + 1)
        #expect(changed.activeNetworkProfiles == [platformProfile])
    }
}

private final class CustomPrivatePathMemoryStore:
    CmxIrohInstallStateStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(forKey key: String) -> String? {
        lock.withLock { values[key] }
    }

    func set(_ value: String?, forKey key: String) {
        lock.withLock { values[key] = value }
    }
}
