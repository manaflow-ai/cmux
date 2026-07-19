import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellManualHostReconnectTests {
    @Test(arguments: ["100.64.0.5", "copied-manual.tailnet.ts.net"])
    func tailscaleLookingManualEntryStillRequiresApproval(host: String) async {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { Date() },
            supportedRouteKinds: [.manualHost, .tailscale],
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite(
            runtime: runtime,
            workspaces: [],
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            reachability: AlwaysOnlineReachability(),
            manualHostTrustStore: InMemoryMobileManualHostTrustStore()
        )
        store.signIn()

        let result = await store.connectManualHost(
            name: "Copied Manual Mac",
            host: host,
            port: CmxMobileDefaults.defaultHostPort
        )

        #expect(result == .needsUserApproval)
        #expect(store.manualHostTrustWarning?.endpoint == "\(host):58465")
        #expect(await router.count(of: "mobile.attach_ticket.create") == 0)
        #expect(await router.count(of: "workspace.list") == 0)
    }

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
        await router.setHostIdentity(deviceID: "manual-mac", instanceTag: nil, displayName: "Manual Mac")
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

    @Test func workspaceOpenWaitsForManualHostApprovalAndResumesTheOriginalSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let manualRoute = try hostPortRoute(kind: .manualHost, host: "192.168.89.2")
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
        await router.setHostIdentity(deviceID: "manual-mac", instanceTag: nil, displayName: "Manual Mac")
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
        store.setWorkspaceStatesForTesting([
            "manual-mac": MacWorkspaceState(
                macDeviceID: "manual-mac",
                displayName: "Manual Mac",
                workspaces: [
                    MobileWorkspacePreview(
                        id: "live-workspace",
                        macDeviceID: "manual-mac",
                        name: "Requested Workspace",
                        terminals: []
                    ),
                ],
                status: .connected
            ),
        ], foregroundMacDeviceID: "other-mac")
        let requestedWorkspaceID = try #require(store.workspaces.first?.id)
        store.selectedWorkspaceID = requestedWorkspaceID

        await store.openWorkspace(requestedWorkspaceID)

        #expect(store.manualHostTrustWarning?.endpoint == "192.168.89.2:58465")
        #expect(store.selectedWorkspaceID == requestedWorkspaceID)

        let approved = await store.acceptManualHostTrustWarning()

        #expect(approved == .connected)
        #expect(store.selectedWorkspace?.rpcWorkspaceID == "live-workspace")
    }

    @Test func newPairingURLSupersedesPendingManualHostSwitchApproval() async throws {
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
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: LivenessHostRouter(), box: TransportBox()),
            now: { Date() },
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
        let supersedingResult = await store.connectPairingURLResult("not a cmux pairing url")

        #expect(!switched)
        #expect(supersedingResult == .failed)
        #expect(store.manualHostTrustWarning == nil)
        #expect(!store.isMacSwitchInFlight)
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

    @Test func approvedTailscaleLookingStoredManualHostKeepsManualRouteKind() async throws {
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
        let attempts = RouteAttemptRecorder()
        await router.setHostIdentity(deviceID: "manual-mac", instanceTag: nil, displayName: "Manual Mac")
        let runtime = LivenessTestRuntime(
            transportFactory: ManualFallbackApprovalTransportFactory(router: router, box: box, attempts: attempts),
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
        let queued = await store.reconnectActiveMacIfAvailable(stackUserID: "phone-user")

        #expect(!queued)
        #expect(store.manualHostTrustWarning?.endpoint == "100.64.0.5:58465")
        #expect(attempts.count(.manualHost) == 0)
        #expect(attempts.count(.tailscale) == 0)

        let approved = await store.acceptManualHostTrustWarning()

        #expect(approved == .connected)
        #expect(store.activeRoute?.kind == .manualHost)
        #expect(attempts.count(.manualHost) >= 1)
        #expect(attempts.count(.tailscale) == 0)
    }

    @Test func failedRegistryConnectDoesNotAcceptExistingConnectionAtSameEndpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let oldRoute = try CmxAttachRoute(
            id: "old-route",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
        )
        let targetRoute = try CmxAttachRoute(
            id: "target-route",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
        )
        try await pairedMacStore.upsert(
            macDeviceID: "old-mac",
            displayName: "Old Mac",
            routes: [oldRoute],
            markActive: true,
            stackUserID: "phone-user",
            teamID: nil,
            now: Date().addingTimeInterval(-10)
        )
        try await pairedMacStore.upsert(
            macDeviceID: "target-mac",
            displayName: "Target Mac",
            routes: [targetRoute],
            markActive: false,
            stackUserID: "phone-user",
            teamID: nil,
            now: Date()
        )
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "old-mac", instanceTag: nil, displayName: "Old Mac")
        let runtime = LivenessTestRuntime(
            transportFactory: RouteSelectiveFailureTransportFactory(
                failingRouteID: targetRoute.id,
                router: router,
                box: TransportBox()
            ),
            now: { Date() },
            supportedRouteKinds: [.debugLoopback],
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
        let oldTicket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "old-mac",
            macDisplayName: "Old Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [oldRoute],
            expiresAt: Date().addingTimeInterval(3_600),
            authToken: "old-ticket"
        )
        #expect(await store.connectPairingURL(try attachURL(for: oldTicket)))
        let device = RegistryDevice(
            deviceId: "target-mac",
            platform: "mac",
            displayName: "Target Mac",
            lastSeenAt: Date(),
            instances: []
        )
        let instance = RegistryAppInstance(tag: "stale", routes: [targetRoute], lastSeenAt: Date())

        await store.connectToRegistryInstance(device: device, instance: instance)

        let activeIDs = try await pairedMacStore
            .loadAll(stackUserID: "phone-user", teamID: nil)
            .filter(\.isActive)
            .map(\.macDeviceID)
        #expect(activeIDs == ["old-mac"])
        #expect(store.connectionState == .connected)
        #expect(store.foregroundMacDeviceIDForTesting() == "old-mac")
    }

    private func hostPortRoute(kind: CmxAttachTransportKind, host: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: kind.rawValue,
            kind: kind,
            endpoint: .hostPort(host: host, port: CmxMobileDefaults.defaultHostPort)
        )
    }
}
