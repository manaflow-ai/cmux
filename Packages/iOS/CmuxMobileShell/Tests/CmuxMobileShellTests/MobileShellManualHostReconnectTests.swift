import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellManualHostReconnectTests {
    @Test func activeManualHostReconnectWaitsForApprovalInsteadOfSwitchingMacs() async throws {
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

        #expect(!connected)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectedMacDeviceID == nil)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.77:58465")
    }

    @Test func switchToManualHostMacResumesAfterApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let manualRoute = try hostPortRoute(kind: .manualHost, host: "192.168.89.1")
        try await pairedMacStore.upsert(
            macDeviceID: "manual-mac",
            displayName: "Manual Mac",
            routes: [manualRoute],
            markActive: false,
            stackUserID: "phone-user",
            teamID: nil,
            now: Date()
        )
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
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

        let switched = await store.switchToMac(macDeviceID: "manual-mac")

        #expect(!switched)
        #expect(store.isMacSwitchInFlight)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.89.1:58465")
        #expect(await router.count(of: "mobile.attach_ticket.create") == 0)
        #expect(await router.count(of: "workspace.list") == 0)

        let approved = await store.acceptManualHostTrustWarning()

        #expect(approved == .connected)
        #expect(!store.isMacSwitchInFlight)
        #expect(store.connectionState == .connected)
        #expect(store.manualHostTrustWarning == nil)
        #expect(await router.count(of: "mobile.attach_ticket.create") == 1)
        #expect(await router.count(of: "workspace.list") >= 1)
    }

    @Test func tailscaleLookingStoredManualHostStillRequiresApprovalBeforeReconnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let manualRoute = try hostPortRoute(kind: .manualHost, host: "100.64.0.5")
        try await pairedMacStore.upsert(
            macDeviceID: "manual-mac",
            displayName: "Manual Mac",
            routes: [manualRoute],
            markActive: true,
            stackUserID: "phone-user",
            teamID: nil,
            now: Date()
        )
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
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

        #expect(!connected)
        #expect(store.manualHostTrustWarning?.endpoint == "100.64.0.5:58465")
        #expect(await router.count(of: "mobile.attach_ticket.create") == 0)
        #expect(await router.count(of: "workspace.list") == 0)
    }

    private func hostPortRoute(kind: CmxAttachTransportKind, host: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: kind.rawValue,
            kind: kind,
            endpoint: .hostPort(host: host, port: CmxMobileDefaults.defaultHostPort)
        )
    }
}
