import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
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
    private func loopback(_ port: Int = 50906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: 0
        )
    }

    private func tailscale(_ port: Int = 50906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: port),
            priority: 10
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

    @Test func physicalDeviceFallsBackToLoopbackWhenItIsTheOnlyRoute() throws {
        // The on-device XCUITest mock host serves a real listener on 127.0.0.1.
        let pick = MobileShellComposite.firstReconnectHostPortRoute(
            [try loopback()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "127.0.0.1")
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

    @Test func physicalDeviceCandidatesUseLoopbackOnlyAsSoleSupportedRoute() throws {
        // The on-device XCUITest mock host serves a real listener on 127.0.0.1
        // and advertises no other route.
        let candidates = MobileShellComposite.reconnectHostPortRoutes(
            [try loopback()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )

        #expect(candidates.map { $0.host } == ["127.0.0.1"])
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

    private func iroh() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                id: "827b8213a588038820428bc8aa4c1b08ae635fd12c6899d935ee1348caa16123",
                relayHint: nil,
                directAddrs: ["192.168.1.20:52186"],
                relayURL: nil
            ),
            priority: 20
        )
    }

    @Test func irohOnlyMacYieldsItsPeerRouteForReconnect() throws {
        // The cmuxRelay dogfood failure: a Mac in cmuxRelay mode publishes ONLY
        // an iroh peer route. The host/port-only selection returned nil, so the
        // stored-Mac auto-connect never dialed and the phone sat disconnected
        // until re-paired. Full-route selection must return the iroh route.
        let pick = MobileShellComposite.firstReconnectRoute(
            [try iroh()],
            supportedKinds: [.debugLoopback, .tailscale, .iroh],
            preferNonLoopback: true
        )
        #expect(pick?.kind == .iroh)
    }

    @Test func hostPortRouteStillPreferredWhenBothExist() throws {
        // A Mac publishing both lanes keeps the proven host/port behavior
        // (including the IP-literal preference); iroh is the fallback, not an
        // override.
        let pick = MobileShellComposite.firstReconnectRoute(
            [try iroh(), try tailscale()],
            supportedKinds: [.debugLoopback, .tailscale, .iroh],
            preferNonLoopback: true
        )
        #expect(pick?.kind == .tailscale)
        if case let .hostPort(host, _) = pick?.endpoint {
            #expect(host == "100.82.214.112")
        } else {
            Issue.record("expected host/port endpoint")
        }
    }

    @Test func irohRouteSkippedWhenTransportUnsupported() throws {
        // A build without the iroh transport registered (release today) must not
        // select a route it cannot dial.
        let pick = MobileShellComposite.firstReconnectRoute(
            [try iroh()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick == nil)
    }

    @Test func candidatesTryHostPortFirstThenIroh() throws {
        // The dogfood failure mode: a stored STALE tailscale route (the Mac
        // moved to iroh-only cmuxRelay) plus the freshly-paired iroh route. The
        // dial order must be host/port first (existing behavior), then the iroh
        // peer as fallback — so one dead TCP dial no longer skips the whole Mac.
        let candidates = MobileShellComposite.reconnectRouteCandidates(
            [try tailscale(), try iroh()],
            supportedKinds: [.debugLoopback, .tailscale, .iroh],
            preferNonLoopback: true
        )
        #expect(candidates.map(\.kind) == [.tailscale, .iroh])
    }

    @Test func candidatesAreIrohOnlyForACmuxRelayMac() throws {
        let candidates = MobileShellComposite.reconnectRouteCandidates(
            [try iroh()],
            supportedKinds: [.debugLoopback, .tailscale, .iroh],
            preferNonLoopback: true
        )
        #expect(candidates.map(\.kind) == [.iroh])
    }

    @Test func fullRouteSelectionMatchesHostPortChoice() throws {
        // The route-returning selection must pick the SAME endpoint the legacy
        // host/port selection proved reachable (loopback deprioritized on device).
        let pick = MobileShellComposite.firstReconnectRoute(
            [try loopback(), try tailscale()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        if case let .hostPort(host, port) = pick?.endpoint {
            #expect(host == "100.82.214.112")
            #expect(port == 50906)
        } else {
            Issue.record("expected host/port endpoint")
        }
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
            storedRoutes: [stale, connected]
        )

        #expect(merged.map { $0.id }.contains(stale.id))
        #expect(merged.map { $0.id }.contains(connected.id))
        #expect(merged.count == 2)
    }

    // The branch dials at most one host/port candidate plus one iroh peer per
    // Mac (``reconnectRouteCandidates`` = single host/port + iroh fallback), so
    // the stale->good fall-through it actually performs is host/port -> iroh:
    // a Mac whose stored host/port route went stale (moved to the iroh-only
    // cmuxRelay lane) still connects over its stored iroh peer instead of the
    // whole Mac being skipped after one dead host/port dial. These two tests
    // use that real vehicle (loopback host/port `stale` + iroh peer `good`)
    // rather than two loopback routes, which the branch intentionally collapses
    // to a single dial candidate (loopback = the sole XCUITest mock host).

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
                try irohRoute(id: "good", endpointID: "good-node"),
            ],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.debugLoopback, .iroh]
            )
        )

        let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")

        #expect(connected)
        #expect(store.connectionState == .connected)
        // Stale host/port dialed once (its ticket mint fails fast), then the
        // iroh peer connects: minted once, attached once. Proves the single
        // reconnect call fell through the dead host/port route to the good peer.
        #expect(factory.attemptedRoutes() == ["51000", "iroh:good-node", "iroh:good-node"])
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
                try irohRoute(id: "good", endpointID: "good-node"),
            ],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.debugLoopback, .iroh]
            )
        )

        let first = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        let firstRouteReached = try await pollUntil {
            factory.attemptedRoutes() == ["51000"]
        }
        #expect(firstRouteReached)

        let second = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        let secondConnected = await second.value
        factory.releaseHeldConnect()
        let firstConnected = await first.value

        // The first attempt is held on the stale host/port dial; the second
        // reconnect bumps the generation and completes the host/port -> iroh
        // fall-through. When the first's held dial finally fails it sees the
        // superseded generation and aborts instead of also iterating to the
        // iroh peer, so the good peer is dialed only by the winning attempt.
        #expect(!firstConnected)
        #expect(secondConnected)
        #expect(factory.attemptedRoutes() == ["51000", "iroh:good-node", "iroh:good-node"])
    }

    private func loopbackRoute(id: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: port
        )
    }

    private func irohRoute(id: String, endpointID: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .iroh,
            endpoint: .peer(
                id: endpointID,
                relayHint: nil,
                directAddrs: ["192.168.1.20:52186"],
                relayURL: nil
            ),
            priority: 51001
        )
    }

    private func makeReconnectStore(
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
            pairingHintDefaults: UserDefaults(suiteName: "reconnect-routes-\(UUID().uuidString)")!
        )
        await store.loadPairedMacs()
        return store
    }

    private func makePairedMacStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        return (store, directory)
    }
}
