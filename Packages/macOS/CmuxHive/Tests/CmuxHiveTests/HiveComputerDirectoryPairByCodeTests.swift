import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxHive

/// pair(code:) — the registry-rendezvous claim for the 6-digit code another
/// Mac's "Pair This Mac" row shows. The directory's injected clock is epoch
/// 1000, so labels expiring at epoch 2000 are live and epoch 500 expired.
@Suite struct HiveComputerDirectoryPairByCodeTests {
    private let fixture = HiveDirectoryTestFixture()
    private static let liveExpiry = "1970-01-01T00:33:20Z" // epoch 2000
    private static let pastExpiry = "1970-01-01T00:08:20Z" // epoch 500

    private func codedDevice(
        deviceId: String,
        code: String,
        expiry: String = Self.liveExpiry,
        tag: String = "stable",
        route: CmxAttachRoute
    ) -> RegistryDevice {
        RegistryDevice(
            deviceId: deviceId,
            platform: "mac",
            displayName: "Coded Mac",
            lastSeenAt: Date(timeIntervalSince1970: 950),
            instances: [
                RegistryAppInstance(
                    tag: tag,
                    routes: [route],
                    lastSeenAt: Date(timeIntervalSince1970: 900),
                    labels: [
                        CmxPairingCode.codeLabelKey: code,
                        CmxPairingCode.expiresAtLabelKey: expiry,
                    ]
                )
            ]
        )
    }

    @MainActor
    @Test func pairByCodeClaimsTheUniqueLiveMatch() async throws {
        let (store, cleanup) = try fixture.makeTempStore()
        defer { cleanup() }
        let route = try fixture.tailscaleRoute()
        let device = codedDevice(deviceId: "coded-mac", code: "042117", route: route)
        let directory = fixture.makeDirectory(registry: .ok([device]), store: store)

        let outcome = await directory.pair(code: " 042 117 ")
        #expect(outcome == .paired(deviceID: "coded-mac"))

        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.count == 1)
        #expect(persisted.first?.macDeviceID == "coded-mac")
        #expect(persisted.first?.routes == [route])
        #expect(persisted.first?.instanceTag == "stable")
    }

    @MainActor
    @Test func pairByCodeRejectsWrongExpiredAndMalformedCodes() async throws {
        let (store, cleanup) = try fixture.makeTempStore()
        defer { cleanup() }
        let live = codedDevice(deviceId: "coded-mac", code: "042117", route: try fixture.tailscaleRoute())
        let expired = codedDevice(
            deviceId: "expired-mac",
            code: "555555",
            expiry: Self.pastExpiry,
            route: try fixture.tailscaleRoute(host: "100.64.0.10")
        )
        let directory = fixture.makeDirectory(registry: .ok([live, expired]), store: store)

        #expect(await directory.pair(code: "000000") == .codeNotFound)
        #expect(await directory.pair(code: "555555") == .codeNotFound)
        #expect(await directory.pair(code: "4211") == .codeNotFound)
        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.isEmpty)
    }

    @MainActor
    @Test func pairByCodeRefusesAmbiguousDuplicates() async throws {
        let (store, cleanup) = try fixture.makeTempStore()
        defer { cleanup() }
        let first = codedDevice(deviceId: "mac-a", code: "042117", route: try fixture.tailscaleRoute())
        let second = codedDevice(
            deviceId: "mac-b",
            code: "042117",
            route: try fixture.tailscaleRoute(host: "100.64.0.11")
        )
        let directory = fixture.makeDirectory(registry: .ok([first, second]), store: store)

        #expect(await directory.pair(code: "042117") == .codeNotFound)
        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.isEmpty)
    }

    @MainActor
    @Test func pairByCodeRejectsThisMacsOwnCode() async throws {
        let (store, cleanup) = try fixture.makeTempStore()
        defer { cleanup() }
        let own = codedDevice(deviceId: "self-device", code: "042117", route: try fixture.tailscaleRoute())
        let directory = fixture.makeDirectory(registry: .ok([own]), store: store)

        #expect(await directory.pair(code: "042117") == .loopbackRejected)
        let persisted = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        #expect(persisted.isEmpty)
    }
}
