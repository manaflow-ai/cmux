import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Regressions for manual-host trust approval during a Mac switch: a queued
/// approval must survive the remaining route candidates, and the approved
/// switch must persist its target as the active Mac.
@MainActor
@Suite struct ManualHostSwitchApprovalRegressionTests {
    @Test func secondManualCandidateDoesNotClobberPendingSwitchApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // Two untrusted manual-host candidates for ONE Mac. Dialing the second
        // must not supersede the approval the first already queued.
        try await pairedMacStore.upsert(
            macDeviceID: "lan-mac",
            displayName: "LAN Mac",
            routes: [
                try manualRoute(host: "192.168.89.10", port: 58_465, priority: 10),
                try manualRoute(host: "192.168.89.11", port: 58_466, priority: 20),
            ],
            markActive: false,
            stackUserID: "phone-user",
            teamID: nil,
            now: Date()
        )
        let store = try await makeStore(pairedMacStore: pairedMacStore)

        let switched = await store.switchToMac(macDeviceID: "lan-mac")

        #expect(!switched)
        // The FIRST candidate owns the pending approval; iterating on to the
        // second candidate would rotate the pairing attempt and finish the
        // switch attempt, stranding the user's approval as `.superseded`.
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.89.10:58465")
        #expect(store.isMacSwitchInFlight)

        let approved = await store.acceptManualHostTrustWarning()

        #expect(approved == .connected)
        #expect(store.connectionState == .connected)
        #expect(!store.isMacSwitchInFlight)
    }

    @Test func approvedManualHostSwitchPersistsTheConnectedMacAsActive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // The router fixture identifies the host as "test-mac"; the stored row
        // uses the same real device id, as a paired manual host does after its
        // first identity recovery.
        try await pairedMacStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [try manualRoute(host: "192.168.89.21", port: 58_465, priority: 10)],
            markActive: false,
            stackUserID: "phone-user",
            teamID: nil,
            now: Date()
        )
        let store = try await makeStore(pairedMacStore: pairedMacStore, deviceID: "test-mac")

        let switched = await store.switchToMac(macDeviceID: "test-mac")
        #expect(!switched)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.89.21:58465")

        let approved = await store.acceptManualHostTrustWarning()

        #expect(approved == .connected)
        #expect(store.connectionState == .connected)
        // The approved switch is a switch success: identity recovery during the
        // resumed connect must leave the connected Mac persisted as active, or
        // the next relaunch reconnects to the previously-active Mac instead.
        let activeMac = try await pairedMacStore.activeMac(
            stackUserID: "phone-user",
            teamID: nil
        )
        #expect(activeMac?.macDeviceID == "test-mac")
    }

    private func makeStore(
        pairedMacStore: MobilePairedMacStore,
        deviceID: String = "lan-mac"
    ) async throws -> MobileShellComposite {
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: deviceID, instanceTag: nil, displayName: "LAN Mac")
        let clock = TestClock()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { clock.now },
            supportedRouteKinds: [.manualHost],
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite(
            runtime: runtime,
            workspaces: [],
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            reachability: AlwaysOnlineReachability(),
            manualHostTrustStore: InMemoryMobileManualHostTrustStore()
        )
        store.signIn()
        await store.loadPairedMacs()
        return store
    }

    private func manualRoute(host: String, port: Int, priority: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "manual-\(host)-\(port)",
            kind: .manualHost,
            endpoint: .hostPort(host: host, port: port),
            priority: priority
        )
    }
}
