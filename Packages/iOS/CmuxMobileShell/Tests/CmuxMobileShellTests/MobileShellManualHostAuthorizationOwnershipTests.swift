import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellManualHostAuthorizationOwnershipTests {
    @Test func expiredActiveManualTrustQueuesReapprovalWithoutAnotherRPC() async throws {
        let trustStore = ImmediateExpiryManualHostTrustStore()
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { Date() },
            supportedRouteKinds: [.manualHost],
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite(
            runtime: runtime,
            workspaces: [],
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            reachability: AlwaysOnlineReachability(),
            manualHostTrustStore: trustStore
        )
        store.signIn()

        let connected = await store.connectManualHost(
            name: "Expiring LAN Mac",
            host: "192.168.1.77",
            port: 58_465
        )
        let reapprovalQueued = try await pollUntil(attempts: 50) {
            store.manualHostTrustWarning != nil
        }

        #expect(connected == .connected)
        #expect(reapprovalQueued)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.77:58465")
        #expect(store.connectionState == .disconnected)
        #expect(store.remoteClient == nil)
    }

    @Test func revokedForegroundTrustQueuesHostApprovalWithoutAccountReauth() async throws {
        let route = try hostPortRoute(kind: .manualHost, host: "192.168.1.77", port: 58_465)
        let trustStore = InMemoryMobileManualHostTrustStore()
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { Date() },
            supportedRouteKinds: [.manualHost],
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite(
            runtime: runtime,
            workspaces: [],
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            reachability: AlwaysOnlineReachability(),
            manualHostTrustStore: trustStore
        )
        store.signIn()

        let queued = await store.connectManualHost(
            name: "Studio Mac",
            host: "192.168.1.77",
            port: 58_465
        )
        let connected = await store.acceptManualHostTrustWarning()
        #expect(queued == .needsUserApproval)
        #expect(connected == .connected)
        #expect(store.activeRoute?.kind == route.kind)

        let secondaryRoute = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: 56_585
        )
        let secondaryTicket = try ticket(
            route: secondaryRoute,
            macDeviceID: "secondary-mac",
            authToken: "secondary-ticket"
        )
        let secondaryClient = MobileCoreRPCClient(
            runtime: runtime,
            route: secondaryRoute,
            ticket: secondaryTicket,
            authScope: MobileRPCAuthScope(),
            authScopeValidator: { true }
        )
        let secondarySubscription = SecondaryMacSubscription(
            macDeviceID: "secondary-mac",
            client: secondaryClient,
            route: secondaryRoute,
            ticket: secondaryTicket,
            supportedHostCapabilities: [],
            actionCapabilities: MobileWorkspaceActionCapabilities()
        )
        store.secondaryMacSubscriptions["secondary-mac"] = secondarySubscription

        await trustStore.removeAll()
        store.terminalInputText = "pwd"
        await store.submitTerminalInput()

        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.77:58465")
        #expect(!store.connectionRequiresReauth)
        #expect(store.connectionState == .disconnected)
        #expect(store.secondaryMacSubscriptions["secondary-mac"] === secondarySubscription)

        let reconnected = await store.acceptManualHostTrustWarning()
        #expect(reconnected == .connected)
        #expect(!store.connectionRequiresReauth)
    }

    @Test func secondaryTrustFailureDoesNotDisconnectForegroundConnection() async throws {
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "foreground-mac", instanceTag: nil, displayName: "Foreground Mac")
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { Date() },
            supportedRouteKinds: [.debugLoopback, .manualHost],
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        let foregroundRoute = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: 56_584
        )
        let foregroundTicket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "foreground-mac",
            macDisplayName: "Foreground Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [foregroundRoute],
            expiresAt: Date().addingTimeInterval(3_600),
            authToken: "foreground-ticket"
        )
        #expect(await store.connectPairingURL(try attachURL(for: foregroundTicket)))
        let foregroundClient = try #require(store.remoteClient)

        let secondaryRoute = try hostPortRoute(
            kind: .manualHost,
            host: "192.168.1.88",
            port: 58_465
        )
        let secondaryTicket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "secondary-mac",
            macDisplayName: "Secondary Mac",
            routes: [secondaryRoute],
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let secondaryClient = MobileCoreRPCClient(
            runtime: runtime,
            route: secondaryRoute,
            ticket: secondaryTicket,
            allowsStackAuthFallback: true,
            manualHostStackAuthTrustProvider: { false },
            authScope: MobileRPCAuthScope(),
            authScopeValidator: { true }
        )
        let actionCapabilities = MobileWorkspaceActionCapabilities(supportsWorkspaceActions: true)
        store.secondaryMacSubscriptions["secondary-mac"] = SecondaryMacSubscription(
            macDeviceID: "secondary-mac",
            client: secondaryClient,
            route: secondaryRoute,
            ticket: secondaryTicket,
            supportedHostCapabilities: ["workspace.actions.v1"],
            actionCapabilities: actionCapabilities
        )
        let foregroundWorkspace = MobileWorkspacePreview(
            id: "live-workspace",
            macDeviceID: "foreground-mac",
            name: "Foreground Workspace",
            terminals: []
        )
        let secondaryWorkspace = MobileWorkspacePreview(
            id: "secondary-workspace",
            macDeviceID: "secondary-mac",
            name: "Secondary Workspace",
            terminals: []
        )
        store.setWorkspaceStatesForTesting([
            "foreground-mac": MacWorkspaceState(
                macDeviceID: "foreground-mac",
                workspaces: [foregroundWorkspace],
                status: .connected
            ),
            "secondary-mac": MacWorkspaceState(
                macDeviceID: "secondary-mac",
                workspaces: [secondaryWorkspace],
                status: .connected,
                actionCapabilities: actionCapabilities
            ),
        ], foregroundMacDeviceID: "foreground-mac")
        let secondaryRowID = try #require(
            store.workspaces.first(where: { $0.macDeviceID == "secondary-mac" })?.id
        )

        let result = await store.renameWorkspace(id: secondaryRowID, title: "Renamed")

        guard case .failure(.authorizationFailed) = result else {
            Issue.record("Expected the secondary mutation to report authorization failure")
            return
        }
        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === foregroundClient)
        #expect(store.connectedMacDeviceID == "foreground-mac")
        #expect(!store.connectionRequiresReauth)
        #expect(store.secondaryMacSubscriptions["secondary-mac"] == nil)
    }

    @Test func staleForegroundAuthorizationFailureDoesNotDisconnectReplacementClient() async throws {
        let oldRouter = LivenessHostRouter()
        await oldRouter.setHostIdentity(deviceID: "old-mac", instanceTag: nil, displayName: "Old Mac")
        let failureGate = HeldAuthorizationFailureGate()
        let oldRuntime = LivenessTestRuntime(
            transportFactory: HeldAuthorizationFailureTransportFactory(
                method: "workspace.action",
                gate: failureGate,
                router: oldRouter
            ),
            now: { Date() },
            supportedRouteKinds: [.debugLoopback],
            supportsServerPushEvents: false
        )
        let oldRoute = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 56_584)
        let newRoute = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 56_585)
        let oldTicket = try ticket(route: oldRoute, macDeviceID: "old-mac", authToken: "old-ticket")
        let newTicket = try ticket(route: newRoute, macDeviceID: "new-mac", authToken: "new-ticket")
        let newClient = MobileCoreRPCClient(
            runtime: oldRuntime,
            route: newRoute,
            ticket: newTicket,
            authScope: MobileRPCAuthScope(),
            authScopeValidator: { true }
        )
        let store = MobileShellComposite.preview(runtime: oldRuntime)
        store.signIn()
        #expect(await store.connectPairingURL(try attachURL(for: oldTicket)))
        let capabilities = MobileWorkspaceActionCapabilities(supportsWorkspaceActions: true)
        let workspace = MobileWorkspacePreview(
            id: "old-workspace",
            macDeviceID: "old-mac",
            name: "Old Workspace",
            terminals: []
        )
        store.setWorkspaceStatesForTesting([
            "old-mac": MacWorkspaceState(
                macDeviceID: "old-mac",
                workspaces: [workspace],
                status: .connected,
                actionCapabilities: capabilities
            ),
        ], foregroundMacDeviceID: "old-mac")
        let rowID = try #require(store.workspaces.first?.id)
        let rename = Task { @MainActor in
            await store.renameWorkspace(id: rowID, title: "Renamed")
        }
        await failureGate.waitUntilReached()
        store.remoteClient = newClient
        store.setWorkspaceStatesForTesting([:], foregroundMacDeviceID: "new-mac")
        await failureGate.release()
        _ = await rename.value

        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === newClient)
        #expect(store.foregroundMacDeviceIDForTesting() == "new-mac")
        #expect(store.manualHostTrustWarning == nil)
        #expect(!store.connectionRequiresReauth)
    }

    @Test func staleForegroundAuthorizationFailureDoesNotDisconnectNewConnectionGeneration() async throws {
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "foreground-mac", instanceTag: nil, displayName: "Foreground Mac")
        let failureGate = HeldAuthorizationFailureGate()
        let runtime = LivenessTestRuntime(
            transportFactory: HeldAuthorizationFailureTransportFactory(
                method: "workspace.action",
                gate: failureGate,
                router: router
            ),
            now: { Date() },
            supportedRouteKinds: [.debugLoopback],
            supportsServerPushEvents: false
        )
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 56_584)
        let attachTicket = try ticket(route: route, macDeviceID: "foreground-mac", authToken: "ticket")
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        #expect(await store.connectPairingURL(try attachURL(for: attachTicket)))
        let client = try #require(store.remoteClient)
        let capabilities = MobileWorkspaceActionCapabilities(supportsWorkspaceActions: true)
        let workspace = MobileWorkspacePreview(
            id: "workspace",
            macDeviceID: "foreground-mac",
            name: "Workspace",
            terminals: []
        )
        store.setWorkspaceStatesForTesting([
            "foreground-mac": MacWorkspaceState(
                macDeviceID: "foreground-mac",
                workspaces: [workspace],
                status: .connected,
                actionCapabilities: capabilities
            ),
        ], foregroundMacDeviceID: "foreground-mac")
        let rowID = try #require(store.workspaces.first?.id)
        let rename = Task { @MainActor in
            await store.renameWorkspace(id: rowID, title: "Renamed")
        }
        await failureGate.waitUntilReached()
        store.connectionGeneration = UUID()
        await failureGate.release()
        _ = await rename.value

        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === client)
        #expect(store.foregroundMacDeviceIDForTesting() == "foreground-mac")
        #expect(!store.connectionRequiresReauth)
    }

    private func ticket(
        route: CmxAttachRoute,
        macDeviceID: String,
        authToken: String
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: macDeviceID,
            macDisplayName: macDeviceID,
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600),
            authToken: authToken
        )
    }

    private func hostPortRoute(
        kind: CmxAttachTransportKind,
        host: String,
        port: Int
    ) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "\(kind.rawValue)-\(host)-\(port)",
            kind: kind,
            endpoint: .hostPort(host: host, port: port)
        )
    }
}
