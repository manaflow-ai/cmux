import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellManualHostAuthorizationOwnershipTests {
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

        await trustStore.removeAll()
        store.terminalInputText = "pwd"
        await store.submitTerminalInput()

        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.77:58465")
        #expect(!store.connectionRequiresReauth)
        #expect(store.connectionState == .disconnected)

        let reconnected = await store.acceptManualHostTrustWarning()
        #expect(reconnected == .connected)
        #expect(!store.connectionRequiresReauth)
    }

    @Test func secondaryTrustFailureDoesNotDisconnectForegroundConnection() async throws {
        let router = LivenessHostRouter()
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
            manualHostStackAuthTrustProvider: { false }
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
