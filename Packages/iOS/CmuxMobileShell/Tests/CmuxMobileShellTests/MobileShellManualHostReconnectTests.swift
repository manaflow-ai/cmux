import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellManualHostReconnectTests {
    @Test func successfulLaterReconnectCandidateClearsQueuedManualHostApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let manualRoute = try hostPortRoute(kind: .manualHost, host: "192.168.1.77")
        let trustedRoute = try hostPortRoute(kind: .tailscale, host: "100.64.0.5")
        let now = Date()
        try await pairedMacStore.upsert(
            macDeviceID: "manual-mac",
            displayName: "Manual Mac",
            routes: [manualRoute],
            markActive: true,
            stackUserID: "phone-user",
            teamID: nil,
            now: now.addingTimeInterval(-10)
        )
        try await pairedMacStore.upsert(
            macDeviceID: "trusted-mac",
            displayName: "Trusted Mac",
            routes: [trustedRoute],
            markActive: false,
            stackUserID: "phone-user",
            teamID: nil,
            now: now
        )
        let clock = TestClock()
        let runtime = LivenessTestRuntime(
            transportFactory: AttachTicketReconnectTransport(ticketRoute: trustedRoute),
            now: { clock.now },
            supportedRouteKinds: [.manualHost, .tailscale],
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
        let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "phone-user")

        #expect(connected)
        #expect(store.connectionState == .connected)
        #expect(store.connectedMacDeviceID == "trusted-mac")
        #expect(store.manualHostTrustWarning == nil)
    }

    private func hostPortRoute(kind: CmxAttachTransportKind, host: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: kind.rawValue,
            kind: kind,
            endpoint: .hostPort(host: host, port: CmxMobileDefaults.defaultHostPort)
        )
    }
}
