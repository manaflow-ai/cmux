import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxHive

/// Creates isolated stores and deterministic directories shared by the directory suites.
struct HiveDirectoryTestFixture {
    /// Scripted registry double: returns a fixed outcome per call.
    struct Registry: DeviceRegistryRefreshing {
        var outcome: DeviceRegistryListOutcome

        func freshRoutes(forMacDeviceID macDeviceID: String, instanceTag: String?) async -> [CmxAttachRoute]? {
            nil
        }

        func listDevices() async -> DeviceRegistryListOutcome {
            outcome
        }
    }

    @MainActor
    func makeTempStore() throws -> (store: MobilePairedMacStore, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        return (store, { try? FileManager.default.removeItem(at: directory) })
    }

    func tailscaleRoute(host: String = "100.64.0.9", port: Int = 8000) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port)
        )
    }

    @MainActor
    func makeDirectory(
        registry: DeviceRegistryListOutcome,
        store: MobilePairedMacStore,
        ownDeviceID: String = "self-device",
        stackUserID: String? = "user-1",
        teamID: String? = "team-1"
    ) -> HiveComputerDirectory {
        HiveComputerDirectory(
            registry: Registry(outcome: registry),
            pairedStore: store,
            presence: nil,
            ownDeviceID: ownDeviceID,
            scopeProvider: { HiveAccountScope(stackUserID: stackUserID, teamID: teamID) },
            linkDecoder: HivePairingLinkDecoder(allowsLoopbackRoutes: false),
            now: { Date(timeIntervalSince1970: 1_000) },
            presenceRetryDelay: { _ in }
        )
    }
}
