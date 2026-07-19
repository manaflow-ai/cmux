import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellManualHostNetworkEpochTests {
    @Test func networkBoundaryRevokesSecondaryManualHostWithoutDroppingSecureForeground() async throws {
        let reachability = ControllablePathChangeReachability()
        let trustStore = NetworkEpochManualHostTrustStore()
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "foreground-mac", instanceTag: nil, displayName: "Foreground Mac")
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
            id: "secure-foreground",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56_584)
        )
        let foregroundTicket = try CmxAttachTicket(
            workspaceID: "foreground-workspace",
            terminalID: "foreground-terminal",
            macDeviceID: "foreground-mac",
            macDisplayName: "Foreground Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [foregroundRoute],
            expiresAt: Date().addingTimeInterval(3_600),
            authToken: "foreground-ticket"
        )
        #expect(await store.connectPairingURL(try attachURL(for: foregroundTicket)))
        let foregroundClient = try #require(store.remoteClient)
        let secondaryRoute = try CmxAttachRoute(
            id: "manual-secondary",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.88", port: 58_465)
        )
        let secondaryTicket = try CmxAttachTicket(
            workspaceID: "secondary-workspace",
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
            manualHostStackAuthTrustProvider: { true },
            authScope: MobileRPCAuthScope(),
            authScopeValidator: { true }
        )
        store.secondaryMacSubscriptions["secondary-mac"] = SecondaryMacSubscription(
            macDeviceID: "secondary-mac",
            client: secondaryClient,
            route: secondaryRoute,
            ticket: secondaryTicket,
            supportedHostCapabilities: [],
            actionCapabilities: .none
        )
        store.setWorkspaceStatesForTesting([
            "foreground-mac": MacWorkspaceState(
                macDeviceID: "foreground-mac",
                workspaces: [],
                status: .connected
            ),
            "secondary-mac": MacWorkspaceState(
                macDeviceID: "secondary-mac",
                workspaces: [],
                status: .connected
            ),
        ], foregroundMacDeviceID: "foreground-mac")
        store.startObservingNetworkPathChanges()

        reachability.emitPathChange()
        await trustStore.waitUntilRemoved()

        #expect(store.remoteClient === foregroundClient)
        #expect(store.connectionState == .connected)
        #expect(store.secondaryMacSubscriptions["secondary-mac"] == nil)
        #expect(store.workspacesByMac["secondary-mac"]?.status == .unavailable)
    }

    @Test func repeatedBoundaryWhileTrustResetIsPendingDoesNotRestartReset() async {
        let trustStore = BlockingNetworkEpochTrustStore()
        let store = MobileShellComposite(
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            manualHostTrustStore: trustStore
        )
        store.signIn()

        store.invalidateManualHostTrustForNetworkBoundary()
        await trustStore.waitUntilRemoveCount(1)
        store.invalidateManualHostTrustForNetworkBoundary()

        #expect(store.manualHostTrustResetGeneration == 1)
        #expect(await trustStore.currentRemoveCount() == 1)
        await trustStore.releaseRemovals()
    }

    @Test func secondBoundarySupersedesApprovalWaitingForTrustReset() async throws {
        let trustStore = BlockingNetworkEpochTrustStore()
        let store = MobileShellComposite(
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            manualHostTrustStore: trustStore
        )
        store.signIn()
        store.invalidateManualHostTrustForNetworkBoundary()
        await trustStore.waitUntilRemoveCount(1)
        let route = try CmxAttachRoute(
            id: "waiting-manual-host",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: 58_465)
        )
        let firstAttemptID = store.beginPairingValidationAttempt()
        store.queueManualHostTrustWarning(
            route: route,
            displayHost: "192.168.1.77",
            pending: .manual(
                attemptID: firstAttemptID,
                name: "LAN Mac",
                host: "192.168.1.77",
                port: 58_465,
                route: route,
                pairedMacDeviceID: "manual-mac",
                instanceTagExpectation: .adopt,
                recordsPairingAttempt: false,
                macSwitchAttemptID: nil,
                ifStillCurrent: nil
            )
        )
        let firstAuthScope = store.manualHostRPCAuthScope
        let (approvalStarted, approvalStartedContinuation) =
            AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var approvalStartedIterator = approvalStarted.makeAsyncIterator()
        let approval = Task { @MainActor in
            approvalStartedContinuation.yield(())
            return await store.acceptManualHostTrustWarning()
        }
        _ = await approvalStartedIterator.next()

        store.invalidateManualHostTrustForNetworkBoundary()
        let reissuedAttemptID = store.pendingManualHostTrust?.attemptID

        #expect(store.manualHostRPCAuthScope != firstAuthScope)
        #expect(reissuedAttemptID != nil)
        #expect(reissuedAttemptID != firstAttemptID)
        #expect(await trustStore.currentRemoveCount() == 1)
        await trustStore.releaseRemovals()
        let result = await approval.value

        #expect(result == .superseded)
        #expect(await trustStore.currentTrustCount() == 0)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.77:58465")
        store.cancelPairing()
    }

    @Test func foregroundResumeDisconnectsActiveManualHostWithoutAPathEvent() async throws {
        let reachability = ControllablePathChangeReachability()
        let trustStore = NetworkEpochManualHostTrustStore()
        let router = LivenessHostRouter()
        await router.setHostIdentity(deviceID: "manual-mac", instanceTag: nil, displayName: "LAN Mac")
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
        await router.setHostIdentity(deviceID: "manual-mac", instanceTag: nil, displayName: "LAN Mac")
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
        await router.setHostIdentity(deviceID: "foreground-mac", instanceTag: nil, displayName: "Foreground Mac")
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
