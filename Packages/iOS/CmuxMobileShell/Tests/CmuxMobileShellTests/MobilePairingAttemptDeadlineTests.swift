import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobilePairingAttemptDeadlineTests {
    @Test func qrPairingURLTimesOutWithoutWaitingForStuckTransport() async throws {
        let store = makeStore()

        let result = await store.connectPairingURLResult(try Self.pairingURL())

        #expect(result == .failed)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError?.isEmpty == false)
        #expect(store.connectionError?.contains("127.0.0.1") == true)
    }

    @Test func scannedOrPastedPairingInputUsesSameDeadline() async throws {
        let store = makeStore(pairingCode: try Self.pairingURL())

        await store.connectPairingInput()

        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError?.isEmpty == false)
        #expect(store.connectionError?.contains("127.0.0.1") == true)
    }

    @Test func immediatePairingRetryDoesNotStartSecondStuckConnect() async throws {
        let transport = CountingSlowIgnoringCancellationTransport()
        let runtime = PairingDeadlineRuntime(
            transportFactory: CountingSlowIgnoringCancellationTransportFactory(transport: transport),
            pairingAttemptTimeoutNanoseconds: 1_000_000_000
        )
        let store = makeStore(runtime: runtime)
        let pairingURL = try Self.pairingURL()
        let first = await store.connectPairingURLResult(pairingURL)
        let second = await store.connectPairingURLResult(pairingURL)
        let connectCount = await transport.connectCount()
        await transport.releaseStuckConnects()

        #expect(first == .failed)
        #expect(second == .failed)
        #expect(connectCount == 1)
        #expect(store.connectionState == .disconnected)
    }
    @Test func mixedTrustedAndUntrustedRoutesStillConnectOverTrustedRoute() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now },
            supportedRouteKinds: [.debugLoopback, .manualHost]
        )
        let store = makeStore(runtime: runtime)
        let trustedRoute = try CmxAttachRoute(
            id: "a-trusted-loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58_465),
            priority: 0
        )
        let manualFallbackRoute = try CmxAttachRoute(
            id: "b-manual-fallback",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: 58_465),
            priority: 1
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [trustedRoute, manualFallbackRoute],
            expiresAt: clock.now.addingTimeInterval(3600)
        )

        let result = await store.connectPairingURLResult(try attachURL(for: ticket))

        #expect(result == .connected)
        #expect(store.connectionState == .connected)
        #expect(store.manualHostTrustWarning == nil)
        #expect(store.selectedWorkspace?.id.rawValue == "live-workspace")
    }

    @Test func manualFallbackPromptsOnlyAfterTrustedRouteFails() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let attempts = RouteAttemptRecorder()
        let runtime = LivenessTestRuntime(
            transportFactory: ManualFallbackApprovalTransportFactory(
                router: router,
                box: box,
                attempts: attempts,
                failingRouteKind: .debugLoopback
            ),
            now: { clock.now },
            supportedRouteKinds: [.debugLoopback, .manualHost]
        )
        let store = makeStore(runtime: runtime)
        let trustedRoute = try CmxAttachRoute(
            id: "a-trusted-loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58_465),
            priority: 0
        )
        let manualFallbackRoute = try CmxAttachRoute(
            id: "b-manual-fallback",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: 58_465),
            priority: 1
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [trustedRoute, manualFallbackRoute],
            expiresAt: clock.now.addingTimeInterval(3600)
        )

        let result = await store.connectPairingURLResult(try attachURL(for: ticket))

        #expect(result == .needsUserApproval)
        #expect(store.connectionState != .connected)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.77:58465")
        #expect(await router.count(of: "workspace.list") == 0)
        #expect(attempts.count(.debugLoopback) == 1)
        #expect(attempts.count(.manualHost) == 0)

        let approvedResult = await store.acceptManualHostTrustWarning()

        #expect(approvedResult == .connected)
        #expect(store.connectionState == .connected)
        #expect(store.manualHostTrustWarning == nil)
        #expect(store.selectedWorkspace?.id.rawValue == "live-workspace")
        #expect(attempts.count(.debugLoopback) == 1)
        #expect(attempts.count(.manualHost) == 1)
        #expect(await router.count(of: "workspace.list") >= 1)
    }

    @Test func manualFallbackApprovalKeepsExistingConnectionUntilConsent() async throws {
        let clock = TestClock()
        let oldRouter = LivenessHostRouter()
        let oldBox = TransportBox()
        let newRouter = LivenessHostRouter()
        let newBox = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: ManualFallbackApprovalTransportFactory(
                router: newRouter,
                box: newBox,
                failingRouteKind: .debugLoopback
            ),
            now: { clock.now },
            supportedRouteKinds: [.debugLoopback, .manualHost]
        )
        let store = makeStore(runtime: runtime, connectionState: .connected)
        try installFreshLivenessRemoteClient(on: store, router: oldRouter, box: oldBox, clock: clock)
        let originalClient = try #require(store.remoteClient)
        let trustedRoute = try CmxAttachRoute(
            id: "a-trusted-loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58_465),
            priority: 0
        )
        let manualFallbackRoute = try CmxAttachRoute(
            id: "b-manual-fallback",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: 58_465),
            priority: 1
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [trustedRoute, manualFallbackRoute],
            expiresAt: clock.now.addingTimeInterval(3600)
        )

        let result = await store.connectPairingURLResult(try attachURL(for: ticket))

        #expect(result == .needsUserApproval)
        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === originalClient)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.77:58465")
        #expect(await newRouter.count(of: "workspace.list") == 0)

        store.cancelPairing()

        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === originalClient)
        #expect(store.manualHostTrustWarning == nil)
    }

    @Test func manualFallbackCancelClearsDisconnectedStagedContext() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: ManualFallbackApprovalTransportFactory(
                router: router,
                box: box,
                failingRouteKind: .debugLoopback
            ),
            now: { clock.now },
            supportedRouteKinds: [.debugLoopback, .manualHost]
        )
        let store = makeStore(runtime: runtime)
        let trustedRoute = try CmxAttachRoute(
            id: "a-trusted-loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58_465),
            priority: 0
        )
        let manualFallbackRoute = try CmxAttachRoute(
            id: "b-manual-fallback",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: 58_465),
            priority: 1
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [trustedRoute, manualFallbackRoute],
            expiresAt: clock.now.addingTimeInterval(3600),
            authToken: "ticket-secret"
        )

        let result = await store.connectPairingURLResult(try attachURL(for: ticket))

        #expect(result == .needsUserApproval)
        #expect(store.connectionState == .disconnected)
        #expect(store.activeTicket != nil)
        #expect(store.activeRoute?.kind == .manualHost)
        #expect(store.hasActiveUnexpiredAttachTicket)

        store.cancelPairing()

        #expect(store.connectionState == .disconnected)
        #expect(store.manualHostTrustWarning == nil)
        #expect(store.activeTicket == nil)
        #expect(store.activeRoute == nil)
        #expect(!store.hasActiveUnexpiredAttachTicket)
    }

    @Test func failedManualHostAttemptKeepsExistingConnection() async throws {
        let clock = TestClock()
        let oldRouter = LivenessHostRouter()
        let oldBox = TransportBox()
        let runtime = PairingDeadlineRuntime()
        let store = makeStore(runtime: runtime, connectionState: .connected)
        try installFreshLivenessRemoteClient(on: store, router: oldRouter, box: oldBox, clock: clock)
        let originalClient = try #require(store.remoteClient)

        await store.connectManualHost(name: "Bad Route", host: "https://bad.example/path", port: 58_465)

        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === originalClient)
        #expect(store.connectionError?.isEmpty == false)
    }

    @Test func failedManualHostApprovalReportsFailureWhileKeepingExistingConnection() async throws {
        let clock = TestClock()
        let oldRouter = LivenessHostRouter()
        let oldBox = TransportBox()
        let runtime = PairingDeadlineRuntime(supportedRouteKinds: [.manualHost])
        let store = makeStore(runtime: runtime, connectionState: .connected)
        try installFreshLivenessRemoteClient(on: store, router: oldRouter, box: oldBox, clock: clock)
        let originalClient = try #require(store.remoteClient)

        await store.connectManualHost(name: "Bad LAN", host: "192.168.1.77", port: 58_465)
        let result = await store.acceptManualHostTrustWarning()

        #expect(result == .failed)
        #expect(store.connectionState == .connected)
        #expect(store.remoteClient === originalClient)
        #expect(store.connectionError?.isEmpty == false)
    }

    @Test func staleManualHostApprovalDoesNotPersistTrustOrRequestTicket() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now },
            supportedRouteKinds: [.manualHost]
        )
        let trustStore = InMemoryMobileManualHostTrustStore()
        let store = makeStore(runtime: runtime, manualHostTrustStore: trustStore)
        var isCurrent = true

        let queued = await store.connectManualHost(
            name: "Stale LAN",
            host: "192.168.1.77",
            port: 58_465,
            recordsPairingAttempt: true,
            ifStillCurrent: { isCurrent }
        )

        #expect(queued == .needsUserApproval)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.77:58465")

        isCurrent = false
        let approved = await store.acceptManualHostTrustWarning()
        let route = try CmxAttachRoute(
            id: "manual_host",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: 58_465)
        )
        let scope = try #require(MobileManualHostTrustScope(route: route, stackUserID: "test-user"))

        #expect(approved == .superseded)
        #expect(store.manualHostTrustWarning == nil)
        #expect(await trustStore.isTrusted(scope) == false)
        #expect(await router.count(of: "mobile.attach_ticket.create") == 0)
    }
    @Test func staleManualHostApprovalLookupCannotReplaceCurrentPrompt() async throws {
        let trustStore = BlockingManualHostTrustStore()
        let store = makeStore(
            runtime: PairingDeadlineRuntime(supportedRouteKinds: [.manualHost]),
            manualHostTrustStore: trustStore
        )

        let first = Task { @MainActor in
            await store.connectManualHost(
                name: "Old LAN",
                host: "192.168.1.77",
                port: 58_465,
                recordsPairingAttempt: true
            )
        }
        await trustStore.waitUntilFirstLookupIsBlocked()

        let second = await store.connectManualHost(
            name: "New LAN",
            host: "192.168.1.88",
            port: 58_465,
            recordsPairingAttempt: true
        )

        #expect(second == .needsUserApproval)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.88:58465")

        await trustStore.releaseFirstLookup()
        let firstResult = await first.value

        #expect(firstResult == .superseded)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.88:58465")
    }

    @Test func stalePairingURLManualHostApprovalLookupCannotReplaceCurrentPrompt() async throws {
        let trustStore = BlockingManualHostTrustStore()
        let store = makeStore(
            runtime: PairingDeadlineRuntime(supportedRouteKinds: [.manualHost]),
            manualHostTrustStore: trustStore
        )
        let firstURL = try attachURL(for: manualHostTicket(host: "192.168.1.77"))
        let secondURL = try attachURL(for: manualHostTicket(host: "192.168.1.88"))

        let first = Task { @MainActor in
            await store.connectPairingURLResult(firstURL)
        }
        await trustStore.waitUntilFirstLookupIsBlocked()

        let second = await store.connectPairingURLResult(secondURL)

        #expect(second == .needsUserApproval)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.88:58465")

        await trustStore.releaseFirstLookup()
        let firstResult = await first.value

        #expect(firstResult == .superseded)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.88:58465")
    }

    @Test func cancelledPairingURLApprovalDoesNotPersistTrustOrConnect() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now },
            supportedRouteKinds: [.manualHost]
        )
        let trustStore = BlockingManualHostTrustPersistenceStore()
        let store = makeStore(runtime: runtime, manualHostTrustStore: trustStore)
        let route = try CmxAttachRoute(
            id: "manual",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: 58_465)
        )
        let scope = try #require(MobileManualHostTrustScope(route: route, stackUserID: "test-user"))
        let url = try attachURL(for: manualHostTicket(host: "192.168.1.77"))

        let queued = await store.connectPairingURLResult(url)
        #expect(queued == .needsUserApproval)

        let approval = Task { @MainActor in
            await store.acceptManualHostTrustWarning()
        }
        await trustStore.waitUntilTrustIsBlocked()
        approval.cancel()
        store.cancelPairing()
        await trustStore.releaseTrust()
        let result = await approval.value

        #expect(result == .superseded)
        #expect(store.manualHostTrustWarning == nil)
        #expect(await trustStore.isTrusted(scope) == false)
        #expect(await router.count(of: "workspace.list") == 0)
    }

    static func pairingURL() throws -> String {
        let route = try CmxAttachRoute(
            id: "deadline-loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58_465)
        )
        return try attachURL(for: CmxAttachTicket(
            workspaceID: "deadline-workspace",
            terminalID: nil,
            macDeviceID: "deadline-mac",
            macDisplayName: "Deadline Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [route],
            expiresAt: Date().addingTimeInterval(60)
        ))
    }

    private func manualHostTicket(host: String) throws -> CmxAttachTicket {
        let route = try CmxAttachRoute(
            id: "manual-\(host)",
            kind: .manualHost,
            endpoint: .hostPort(host: host, port: 58_465),
            priority: 0
        )
        return try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3600)
        )
    }

    func makeStore(
        runtime: any MobileSyncRuntime = PairingDeadlineRuntime(),
        pairingCode: String = "",
        connectionState: MobileConnectionState = .disconnected,
        manualHostTrustStore: any MobileManualHostTrustStoring = InMemoryMobileManualHostTrustStore()
    ) -> MobileShellComposite {
        MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: connectionState,
            pairingCode: pairingCode,
            identityProvider: StaticIdentityProvider(userID: "test-user"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "pairing-deadline-\(UUID().uuidString)")!,
            manualHostTrustStore: manualHostTrustStore
        )
    }
}
