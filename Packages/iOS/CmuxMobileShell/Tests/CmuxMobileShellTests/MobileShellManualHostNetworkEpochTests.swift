import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellManualHostNetworkEpochTests {
    @Test func foregroundResumeDisconnectsActiveManualHostWithoutAPathEvent() async throws {
        let reachability = ControllablePathChangeReachability()
        let trustStore = NetworkEpochManualHostTrustStore()
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { Date() },
            supportedRouteKinds: [.manualHost],
            supportsServerPushEvents: false
        )
        let route = try CmxAttachRoute(
            id: "foreground-resume-manual-host",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: 58_465)
        )
        let trustScope = try #require(
            MobileManualHostTrustScope(route: route, stackUserID: "phone-user")
        )
        await trustStore.trust(trustScope)
        let store = MobileShellComposite(
            runtime: runtime,
            workspaces: [],
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            reachability: reachability,
            manualHostTrustStore: trustStore
        )
        store.signIn()
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "manual-mac",
            macDisplayName: "LAN Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600),
            authToken: "manual-ticket"
        )
        #expect(await store.connectPairingURL(try attachURL(for: ticket)))
        #expect(store.connectionState == .connected)

        store.suspendForegroundRefresh()
        store.resumeForegroundRefresh()

        try #require(store.connectionState == .disconnected)
        #expect(store.remoteClient == nil)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.77:58465")
        await trustStore.waitUntilRemoved()
        #expect(await trustStore.isTrusted(trustScope) == false)
    }

    @Test func pathChangeDisconnectsActiveManualHostAndQueuesExactRouteForReapproval() async throws {
        let reachability = ControllablePathChangeReachability()
        let trustStore = NetworkEpochManualHostTrustStore()
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { Date() },
            supportedRouteKinds: [.manualHost],
            supportsServerPushEvents: false
        )
        let route = try CmxAttachRoute(
            id: "active-manual-host",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: 58_465)
        )
        let trustScope = try #require(
            MobileManualHostTrustScope(route: route, stackUserID: "phone-user")
        )
        await trustStore.trust(trustScope)
        let store = MobileShellComposite(
            runtime: runtime,
            workspaces: [],
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            reachability: reachability,
            manualHostTrustStore: trustStore
        )
        store.signIn()
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "manual-mac",
            macDisplayName: "LAN Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600),
            authToken: "manual-ticket"
        )
        #expect(await store.connectPairingURL(try attachURL(for: ticket)))
        #expect(store.connectionState == .connected)
        #expect(store.remoteClient != nil)
        store.startObservingNetworkPathChanges()

        reachability.emitPathChange()
        await trustStore.waitUntilRemoved()

        #expect(store.connectionState == .disconnected)
        #expect(store.remoteClient == nil)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.77:58465")
        #expect(await trustStore.isTrusted(trustScope) == false)

        let resumed = await store.acceptManualHostTrustWarning()

        #expect(resumed == .connected)
        #expect(store.connectionState == .connected)
        #expect(store.remoteClient != nil)
    }

    @Test func pathChangeSupersedesPendingManualHostApprovalWithoutTouchingForeground() async throws {
        let reachability = ControllablePathChangeReachability()
        let trustStore = NetworkEpochManualHostTrustStore()
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { Date() },
            supportedRouteKinds: [.debugLoopback, .manualHost],
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite(
            runtime: runtime,
            workspaces: [],
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            reachability: reachability,
            manualHostTrustStore: trustStore
        )
        store.signIn()
        let foregroundRoute = try CmxAttachRoute(
            id: "foreground",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
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
        let queued = await store.connectManualHost(
            name: "LAN Mac",
            host: "192.168.1.77",
            port: 58_465
        )
        let scope = try #require(MobileManualHostTrustScope(
            host: "192.168.1.77",
            port: 58_465,
            stackUserID: "phone-user"
        ))
        #expect(queued == .needsUserApproval)
        store.startObservingNetworkPathChanges()

        reachability.emitPathChange()
        await trustStore.waitUntilRemoved()
        let result = await store.acceptManualHostTrustWarning()

        #expect(result == .superseded)
        #expect(store.manualHostTrustWarning == nil)
        #expect(await trustStore.isTrusted(scope) == false)
        #expect(await router.count(of: "mobile.attach_ticket.create") == 0)
        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === foregroundClient)

        store.terminalInputText = "pwd"
        await store.submitTerminalInput()
        #expect(await router.count(of: "terminal.input") == 1)
    }
}
