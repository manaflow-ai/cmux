import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// A restored/published Mac advertises both a `debug_loopback` route
/// (`127.0.0.1`, priority 0) and a `tailscale` route. On a physical phone the
/// loopback route names the phone itself and can never reach the Mac, so route
/// selection must prefer the real route there — otherwise tapping a saved Mac
/// dials the phone's own loopback and silently fails to connect.
@MainActor
@Suite struct ReconnectRouteSelectionTests {
    func loopback(_ port: Int = 50906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: 0
        )
    }

    func tailscale(_ port: Int = 50906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: port),
            priority: 10
        )
    }

    func iroh(priority: Int = -10_000) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh-personal",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "a", count: 64)
                ),
                pathHints: []
            ),
            priority: priority
        )
    }

    @Test func physicalDevicePrefersRealRouteOverLowerPriorityLoopback() throws {
        let pick = MobileShellComposite.firstReconnectHostPortRoute(
            [try loopback(), try tailscale()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "100.82.214.112") // tailscale, not the phone's 127.0.0.1
    }

    @Test func physicalDeviceRejectsLoopbackWhenItIsTheOnlyRoute() throws {
        // A stale backup can contain only the Mac's debug loopback route. On a
        // real phone that address names the phone, so reconnect must fail closed
        // instead of dialing a local port that can never reach the Mac.
        let pick = MobileShellComposite.firstReconnectHostPortRoute(
            [try loopback()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick == nil)
    }

    @Test func simulatorKeepsLoopbackPriorityOrder() throws {
        // On the simulator 127.0.0.1 IS the host Mac, so priority order stands.
        let pick = MobileShellComposite.firstReconnectHostPortRoute(
            [try loopback(), try tailscale()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: false
        )
        #expect(pick?.0 == "127.0.0.1")
    }

    @Test func reconnectCandidatesKeepFallbackRoutesAfterPreferredRoute() throws {
        let candidates = MobileShellComposite.reconnectHostPortRoutes(
            [try loopback(), try tailscale()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: false
        )

        #expect(candidates.map { $0.host } == ["127.0.0.1", "100.82.214.112"])
    }

    @Test func physicalDeviceCandidatesNeverIncludeLoopbackWhenRealRoutesExist() throws {
        // Route ITERATION dials every candidate, so the loopback tail entry
        // that single-pick selection never reached must not be in the list at
        // all: dialing 127.0.0.1 on a physical phone reaches whatever local
        // process is listening, and the manual attach path treats loopback as
        // trusted.
        let candidates = MobileShellComposite.reconnectHostPortRoutes(
            [try loopback(), try tailscale()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )

        #expect(candidates.map { $0.host } == ["100.82.214.112"])
    }

    @Test func physicalDeviceCandidatesRejectSoleLoopbackRoute() throws {
        // Candidate iteration must enforce the same fail-closed rule as the
        // single-route helper, otherwise a later caller can reintroduce the bad
        // physical-device dial even when the preferred-route helper is correct.
        let candidates = MobileShellComposite.reconnectHostPortRoutes(
            [try loopback()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )

        #expect(candidates.isEmpty)
    }

    @Test func reconnectCandidatesDeduplicateEndpoints() throws {
        let duplicate = try CmxAttachRoute(
            id: "duplicate",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50906),
            priority: 0
        )

        let candidates = MobileShellComposite.reconnectHostPortRoutes(
            [duplicate, try tailscale()],
            supportedKinds: [.tailscale],
            preferNonLoopback: true
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.routeID == "duplicate")
    }

    @Test func rawReconnectCandidatesAreUnavailableForIrohCapablePairing() throws {
        let candidates = MobileShellComposite.reconnectHostPortRoutes(
            [try tailscale(), try iroh()],
            supportedKinds: [.iroh, .tailscale],
            preferNonLoopback: true
        )

        #expect(candidates.isEmpty)
    }

    private func magicDNS(_ port: Int = 50906) throws -> CmxAttachRoute {
        // A MagicDNS hostname route, advertised BEFORE the IP route by priority.
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "lawrences-macbook-pro-2.tail137216.ts.net", port: port),
            priority: 5
        )
    }

    @Test func physicalDevicePrefersIPLiteralOverMagicDNSHostname() throws {
        // The exact dogfood failure: a Mac advertises loopback, a MagicDNS
        // hostname (higher priority), and the raw tailscale IP. MagicDNS doesn't
        // resolve on the phone, so dialing the hostname times out; selection must
        // pick the IP literal so the secondary fetch / reconnect actually connects.
        let ip = try CmxAttachRoute(
            id: "tailscale_2",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50922),
            priority: 10
        )
        let pick = MobileShellComposite.firstReconnectHostPortRoute(
            [try loopback(50922), try magicDNS(50922), ip],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "100.82.214.112")
    }

    @Test func magicDNSHostnameStillUsedWhenNoIPRouteExists() throws {
        // If the only non-loopback route is a hostname, still prefer it over
        // loopback on device (better than dialing the phone's own 127.0.0.1).
        let pick = MobileShellComposite.firstReconnectHostPortRoute(
            [try loopback(50922), try magicDNS(50922)],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "lawrences-macbook-pro-2.tail137216.ts.net")
    }

    @Test func ipLiteralHostClassification() {
        #expect(MobileShellComposite.isIPLiteralHost("100.82.214.112"))
        #expect(MobileShellComposite.isIPLiteralHost("127.0.0.1"))
        #expect(MobileShellComposite.isIPLiteralHost("fd7a:115c:a1e0::4b36:d670"))
        #expect(!MobileShellComposite.isIPLiteralHost("lawrences-macbook-pro-2.tail137216.ts.net"))
        #expect(!MobileShellComposite.isIPLiteralHost("example.com"))
        #expect(!MobileShellComposite.isIPLiteralHost("100.82.214")) // too few octets
        #expect(!MobileShellComposite.isIPLiteralHost("256.1.1.1")) // out of range
    }

    @Test func constrainedReconnectTicketMergesWithStoredRoutes() throws {
        let stale = try loopback(50906)
        let connected = try tailscale(50922)

        let merged = MobileShellComposite.mergedReconnectRoutes(
            ticketRoutes: [connected],
            storedRoutes: [stale, connected],
            at: .distantPast
        )

        #expect(merged.map { $0.id }.contains(stale.id))
        #expect(merged.map { $0.id }.contains(connected.id))
        #expect(merged.count == 2)
    }

    @Test func reconnectActiveMacFallsThroughStaleRouteToGoodRouteInOneAttempt() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: box,
            failingPorts: [51000]
        )
        let store = try await makeReconnectStore(
            routes: [
                try loopbackRoute(id: "stale", port: 51000),
                try loopbackRoute(id: "good", port: 51001),
            ],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.debugLoopback]
            )
        )

        let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")

        #expect(connected)
        #expect(store.connectionState == .connected)
        #expect(factory.attemptedPorts() == [51000, 51001, 51001])
    }

    @Test func connectionPoolRecordsFallbackRouteThatActuallyConnected() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: box,
            failingPorts: [51000]
        )
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.debugLoopback]
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "pairing-pool-route-\(UUID().uuidString)")!
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [
                try loopbackRoute(id: "stale", port: 51000),
                try loopbackRoute(id: "good", port: 51001),
            ],
            expiresAt: clock.now.addingTimeInterval(3600)
        )

        let result = await store.connectPairingURLResult(try attachURL(for: ticket))

        #expect(result == .connected)
        #expect(store.activeRoute?.id == "good")
        #expect(store.pooledRouteForTesting(macDeviceID: "test-mac")?.id == "good")
    }

    @Test func supersededReconnectGenerationAbortsRouteIteration() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: box,
            failingPorts: [51000],
            holdFirstFailingPort: 51000
        )
        let store = try await makeReconnectStore(
            routes: [
                try loopbackRoute(id: "stale", port: 51000),
                try loopbackRoute(id: "good", port: 51001),
            ],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.debugLoopback]
            )
        )

        let first = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        let firstRouteReached = try await pollUntil {
            factory.attemptedPorts() == [51000]
        }
        #expect(firstRouteReached)

        let second = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        let secondConnected = await second.value
        factory.releaseHeldConnect()
        let firstConnected = await first.value

        #expect(!firstConnected)
        #expect(secondConnected)
        #expect(factory.attemptedPorts() == [51000, 51001, 51001])
    }

    @Test func staleConnectCannotReplaceAnEstablishedClientBeforeDialing() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: box,
            failingPorts: [51000]
        )
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.debugLoopback]
        )
        let liveRoute = try loopbackRoute(id: "live", port: 51001)
        let staleRoute = try loopbackRoute(id: "stale", port: 51000)
        let liveTicket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "live-mac",
            macDisplayName: "Live Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [liveRoute],
            expiresAt: clock.now.addingTimeInterval(3_600)
        )
        let staleTicket = try CmxAttachTicket(
            workspaceID: "stale-workspace",
            terminalID: "stale-terminal",
            macDeviceID: "stale-mac",
            macDisplayName: "Stale Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [staleRoute],
            expiresAt: clock.now.addingTimeInterval(3_600)
        )
        let liveClient = MobileCoreRPCClient(
            runtime: runtime,
            route: liveRoute,
            ticket: liveTicket,
            allowsStackAuthFallback: true
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "stale-connect-authority-\(UUID().uuidString)"
            )!
        )
        store.activeTicket = liveTicket
        store.activeRoute = liveRoute
        store.replaceRemoteClient(with: liveClient)

        _ = try await store.connect(
            ticket: staleTicket,
            ifStillCurrent: { false }
        )

        #expect(store.remoteClient === liveClient)
        #expect(store.connectionState == .connected)
        #expect(factory.attemptedPorts().isEmpty)
    }

    @Test func supersededSuccessfulRouteClosesItsUnadoptedTransport() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        await router.holdWorkspaceListRequest(number: 1)
        let factory = SupersededTransportFactory(router: router)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.debugLoopback]
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "pairing-superseded-close-\(UUID().uuidString)"
            )!
        )
        let route = try loopbackRoute(id: "live", port: 51001)
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults
                .pairingCompatibilityVersion,
            routes: [route],
            expiresAt: clock.now.addingTimeInterval(3_600)
        )

        let first = Task { @MainActor in
            try? await store.connect(ticket: ticket)
        }
        #expect(await router.waitForCount(of: "workspace.list", atLeast: 1))

        let second = Task { @MainActor in
            try? await store.connect(ticket: ticket)
        }
        #expect(await router.waitForCount(of: "workspace.list", atLeast: 2))
        _ = await second.value
        await router.releaseAllHeld()
        _ = await first.value

        let transports = factory.createdTransports()
        #expect(transports.count == 2)
        #expect(await transports.first?.observedCloseCount() == 1)
        #expect(await transports.last?.observedCloseCount() == 0)
        await store.remoteClient?.disconnect()
    }

    @Test func sameDeviceTagSwitchFailureRestoresLiveInstanceRoute() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        await router.setHostIdentity(
            deviceID: "test-mac", instanceTag: "feature-a", displayName: "Test Mac"
        )
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: TransportBox(),
            failingPorts: [51000]
        )
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let routeA = try loopbackRoute(id: "live-a", port: 51001)
        let staleRouteB = try loopbackRoute(id: "stale-b", port: 51000)
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [staleRouteB],
            instanceTag: "feature-b",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now.addingTimeInterval(1)
        )
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.debugLoopback]
        )
        let ticketA = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [routeA],
            expiresAt: clock.now.addingTimeInterval(3_600)
        )
        let liveClientA = MobileCoreRPCClient(
            runtime: runtime,
            route: routeA,
            ticket: ticketA,
            allowsStackAuthFallback: true
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "same-device-tag-rollback-\(UUID().uuidString)"
            )!
        )
        store.activeTicket = ticketA
        store.activeRoute = routeA
        store.activeMacInstanceTag = "feature-a"
        store.foregroundMacDeviceID = "test-mac"
        store.replaceRemoteClient(with: liveClientA)
        await store.loadPairedMacs()

        let switched = await store.switchToMac(macDeviceID: "test-mac")
        #expect(!switched)
        #expect(store.connectionState == .connected)
        #expect(store.foregroundMacDeviceID == "test-mac")
        #expect(store.activeMacInstanceTag == "feature-a")
        #expect(factory.attemptedPorts().contains(51000))
        let restored = try #require(await pairedStore.activeMac(
            stackUserID: "user-1", teamID: nil
        ))
        #expect(restored.instanceTag == "feature-a")
        #expect(restored.routes.first?.endpoint == routeA.endpoint)
        #expect(!restored.routes.contains(where: { $0.endpoint == staleRouteB.endpoint }))
    }

    private func loopbackRoute(id: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: port
        )
    }

    func makeReconnectStore(
        routes: [CmxAttachRoute],
        runtime: any MobileSyncRuntime
    ) async throws -> MobileShellComposite {
        let (pairedStore, _) = try makePairedMacStore()
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: routes,
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date()
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "reconnect-routes-\(UUID().uuidString)")!,
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        return store
    }

    @Test func tailscaleMethodUsesOnlyGrantedTailscaleRoute() throws {
        let tailscale = try tailscale()
        let routes = MobileShellComposite.storedReconnectRoutes(
            [tailscale, try iroh()],
            supportedKinds: [.iroh, .tailscale],
            preferNonLoopback: true,
            tailscaleRequirement: MobileShellComposite.TailscaleRouteRequirement(
                macDeviceID: "test-mac",
                grantRoutes: [tailscale]
            )
        )

        #expect(routes.map(\.kind) == [.tailscale])
    }

    @Test func tailscaleMethodWithoutGrantRejectsEveryRoute() throws {
        let routes = MobileShellComposite.storedReconnectRoutes(
            [try tailscale(), try iroh()],
            supportedKinds: [.iroh, .tailscale],
            preferNonLoopback: true,
            tailscaleRequirement: MobileShellComposite.TailscaleRouteRequirement(
                macDeviceID: "test-mac",
                grantRoutes: []
            )
        )

        #expect(routes.isEmpty)
    }

    @Test func tailscaleMethodRejectsMismatchedGrantWithoutIrohFallback() throws {
        let otherDestination = try tailscale(50907)
        let routes = MobileShellComposite.storedReconnectRoutes(
            [try tailscale(), try iroh()],
            supportedKinds: [.iroh, .tailscale],
            preferNonLoopback: true,
            tailscaleRequirement: MobileShellComposite.TailscaleRouteRequirement(
                macDeviceID: "test-mac",
                grantRoutes: [otherDestination]
            )
        )

        #expect(routes.isEmpty)
    }

    @Test func usableTailscaleAuthorizationRequiresACurrentExactRouteMatch() throws {
        let current = try tailscale()
        let stale = try tailscale(50_907)
        let base = MobilePairedMac(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [current],
            createdAt: .distantPast,
            lastSeenAt: .now,
            isActive: true,
            stackUserID: "user-1"
        )

        let authorized = MobilePairedMac(
            macDeviceID: base.macDeviceID,
            displayName: base.displayName,
            routes: base.routes,
            createdAt: base.createdAt,
            lastSeenAt: base.lastSeenAt,
            isActive: base.isActive,
            stackUserID: base.stackUserID,
            legacyTailscaleRoutes: [current]
        )
        let staleAuthorization = MobilePairedMac(
            macDeviceID: base.macDeviceID,
            displayName: base.displayName,
            routes: base.routes,
            createdAt: base.createdAt,
            lastSeenAt: base.lastSeenAt,
            isActive: base.isActive,
            stackUserID: base.stackUserID,
            legacyTailscaleRoutes: [stale]
        )

        #expect(MobileShellComposite.hasUsableTailscaleAuthorization(in: [authorized]))
        #expect(!MobileShellComposite.hasUsableTailscaleAuthorization(in: [base]))
        #expect(!MobileShellComposite.hasUsableTailscaleAuthorization(
            in: [staleAuthorization]
        ))
    }

    @Test func usableTailscaleAuthorizationFindsLastMacInLargeSnapshot() throws {
        let current = try tailscale()
        let macs = (0 ..< 1_000).map { index in
            MobilePairedMac(
                macDeviceID: "test-mac-\(index)",
                displayName: "Test Mac \(index)",
                routes: [current],
                createdAt: .distantPast,
                lastSeenAt: .distantPast,
                isActive: index == 999,
                stackUserID: "user-1",
                legacyTailscaleRoutes: index == 999 ? [current] : nil
            )
        }

        #expect(MobileShellComposite.hasUsableTailscaleAuthorization(in: macs))
    }

    @Test func tailscaleSetupIsRequiredImmediatelyWhenNoMacIsKnown() {
        let methodDefaults = UserDefaults(
            suiteName: "tailscale-setup-method-\(UUID().uuidString)"
        )!
        methodDefaults.set(
            MobileConnectionMethod.tailscale.rawValue,
            forKey: MobileConnectionMethodStore.methodKey
        )
        let pairingDefaults = UserDefaults(
            suiteName: "tailscale-setup-pairing-\(UUID().uuidString)"
        )!
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionMethodStore: MobileConnectionMethodStore(
                defaults: methodDefaults
            ),
            pairingHintDefaults: pairingDefaults
        )

        #expect(store.pairedMacLoadState == .notLoaded)
        #expect(!store.hasKnownPairedMac)
        #expect(store.tailscaleSetupStatus == .pairingRequired)
        #expect(store.tailscalePairingRequired)
    }

    @Test func knownMacWaitsForRouteLoadBeforeRequiringTailscaleSetup() {
        let methodDefaults = UserDefaults(
            suiteName: "tailscale-load-method-\(UUID().uuidString)"
        )!
        methodDefaults.set(
            MobileConnectionMethod.tailscale.rawValue,
            forKey: MobileConnectionMethodStore.methodKey
        )
        let pairingDefaults = UserDefaults(
            suiteName: "tailscale-load-pairing-\(UUID().uuidString)"
        )!
        pairingDefaults.set(true, forKey: "cmux.mobile.hasKnownPairedMac")
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionMethodStore: MobileConnectionMethodStore(
                defaults: methodDefaults
            ),
            pairingHintDefaults: pairingDefaults
        )

        #expect(store.tailscaleSetupStatus == .loadingAuthorization)
        #expect(!store.tailscalePairingRequired)
        store.pairedMacLoadState = .failed
        #expect(store.tailscaleSetupStatus == .pairingRequired)
        #expect(store.tailscalePairingRequired)
    }

    @Test func projectedTailscaleSetupStatusEvaluatesBeforeMethodSelection() {
        let methodDefaults = UserDefaults(
            suiteName: "tailscale-projected-method-\(UUID().uuidString)"
        )!
        let pairingDefaults = UserDefaults(
            suiteName: "tailscale-projected-pairing-\(UUID().uuidString)"
        )!
        pairingDefaults.set(true, forKey: "cmux.mobile.hasKnownPairedMac")
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionMethodStore: MobileConnectionMethodStore(
                defaults: methodDefaults
            ),
            pairingHintDefaults: pairingDefaults
        )

        #expect(store.tailscaleSetupStatus == .notSelected)
        #expect(
            store.tailscaleSetupStatusWhenSelected == .loadingAuthorization
        )
        store.pairedMacLoadState = .failed
        #expect(
            store.tailscaleSetupStatusWhenSelected == .pairingRequired
        )
    }

    @Test func changingToUnavailableTailscaleDropsLiveIrohWithoutFallback() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        // The factory boxes the live Iroh transport it hands out, so the test
        // can observe physical teardown, not just the store's logical route.
        let liveTransportBox = TransportBox()
        let factory = KindRecordingTransportFactory(
            router: router,
            box: liveTransportBox,
            failingKinds: [.tailscale]
        )
        let tailscale = try tailscale()
        let iroh = try iroh()
        let (pairedStore, directory) = try makePairedMacStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [tailscale, iroh],
            instanceTag: "default",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: clock.now
        )
        try await pairedStore.authorizeUserTailscaleRoutes(
            macDeviceID: "test-mac",
            instanceTag: "default",
            stackUserID: "user-1",
            teamID: nil,
            routes: [tailscale]
        )
        let methodDefaults = UserDefaults(
            suiteName: "connection-method-live-switch-\(UUID().uuidString)"
        )!
        let methodStore = MobileConnectionMethodStore(defaults: methodDefaults)
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            connectionMethodStore: methodStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "connection-method-pairing-hint-\(UUID().uuidString)"
            )!,
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(store.activeRoute?.kind == .iroh)
        #expect(factory.attemptedKinds().filter { $0 == .iroh }.count == 1)

        methodStore.method = .tailscale

        // `activeRoute == nil` only proves the store cleared its logical
        // route; the dropped live Iroh transport must also finish closing so
        // no physical cleanup work is still pending when the test completes.
        let applied = try await pollUntil {
            let liveTransportClosed =
                await liveTransportBox.get()?.isClosedForTesting() == true
            return factory.attemptedKinds().contains(.tailscale)
                && store.connectionState == .disconnected
                && store.activeRoute == nil
                && liveTransportClosed
        }
        #expect(applied)
        #expect(store.activeRoute == nil)
        #expect(factory.attemptedKinds().filter { $0 == .iroh }.count == 1)
    }
}
